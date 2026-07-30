//! On-device persistence for chat sessions.
//!
//! Layout under an app-provided absolute `storage_dir`:
//!
//! ```text
//! {storage_dir}/index.sqlite               — engine SqliteSessionStore (list/search index)
//! {storage_dir}/transcripts/{uuid}.jsonl   — engine-format JSONL transcript (full fidelity)
//! {storage_dir}/metadata/{uuid}.familiar.json — pinned familiar identity snapshot
//! {storage_dir}/.session-lifecycle/pending-forks/{uuid}.pending — incomplete fork quarantine
//! ```
//!
//! Transcripts use the engine's `session_storage` wire format, so files are
//! readable by coven-code tooling and survive engine upgrades via its
//! forward-compatible parser. The SQLite index only serves the browser UI;
//! the JSONL file is the source of truth for restores.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use claurst_core::session_storage::{
    load_transcript, make_assistant_entry, make_user_entry, messages_from_transcript,
    write_transcript_entry, TranscriptEntry,
};
use claurst_core::types::{Message, Role};
use claurst_core::SqliteSessionStore;

use crate::remote::FamiliarIdentity;
use crate::PocketError;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct SessionKey {
    root: PathBuf,
    session_id: String,
}

#[derive(Clone, Copy)]
enum SessionLifecycleState {
    Active(uuid::Uuid),
    PendingFork,
    Tombstoned,
}

#[derive(Default)]
struct SessionLifecycle {
    sessions: HashMap<SessionKey, SessionLifecycleState>,
}

static SESSION_LIFECYCLE_LOCK: LazyLock<tokio::sync::RwLock<SessionLifecycle>> =
    LazyLock::new(|| tokio::sync::RwLock::new(SessionLifecycle::default()));

#[cfg(test)]
#[derive(Default)]
struct SessionTestFaults {
    fail_fork_publication_after_row_once: bool,
    fail_index_delete_remaining: usize,
}

#[cfg(test)]
static SESSION_TEST_FAULTS: LazyLock<std::sync::Mutex<HashMap<PathBuf, SessionTestFaults>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

#[cfg(test)]
static DIRECTORY_SYNC_EVENTS: LazyLock<std::sync::Mutex<Vec<PathBuf>>> =
    LazyLock::new(|| std::sync::Mutex::new(Vec::new()));

#[cfg(test)]
static DIRECTORY_SYNC_FAILURES: LazyLock<std::sync::Mutex<HashMap<PathBuf, usize>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

/// Summary row for the session browser.
#[derive(uniffi::Record)]
pub struct ChatSessionSummary {
    /// UUID identifying the session (and its transcript file).
    pub session_id: String,
    /// Derived from the first user message; empty until one is persisted.
    pub title: String,
    /// Model the session was created with.
    pub model: String,
    /// RFC 3339.
    pub created_at: String,
    /// RFC 3339; sessions list newest-first by this.
    pub updated_at: String,
    /// Number of persisted messages (tool-result carriers included).
    pub message_count: u32,
    /// Familiar identity pinned when the session was created.
    pub familiar: Option<FamiliarIdentity>,
}

fn engine_err(context: &str, err: impl std::fmt::Display) -> PocketError {
    PocketError::Engine {
        message: format!("{context}: {err}"),
    }
}

/// Reject anything that is not a bare UUID before it touches a path.
pub(crate) fn validate_session_id(session_id: &str) -> Result<(), PocketError> {
    uuid::Uuid::parse_str(session_id)
        .map(|_| ())
        .map_err(|_| PocketError::Engine {
            message: format!("invalid session id: {session_id}"),
        })
}

fn validate_indexed_session_ids<'a>(
    session_ids: impl IntoIterator<Item = &'a str>,
) -> Result<(), PocketError> {
    session_ids.into_iter().try_for_each(validate_session_id)
}

fn storage_root(storage_dir: &str) -> Result<PathBuf, PocketError> {
    let root = PathBuf::from(storage_dir);
    if !root.is_absolute() {
        return Err(PocketError::Engine {
            message: format!("storage_dir must be absolute, got {storage_dir}"),
        });
    }
    std::fs::create_dir_all(&root).map_err(|e| engine_err("cannot create storage dir", e))?;
    std::fs::canonicalize(&root).map_err(|e| engine_err("cannot canonicalize storage dir", e))
}

fn index_store(root: &Path) -> Result<SqliteSessionStore, PocketError> {
    SqliteSessionStore::open(&root.join("index.sqlite"))
        .map_err(|e| engine_err("cannot open session index", e))
}

fn delete_index_session(root: &Path, session_id: &str, context: &str) -> Result<(), PocketError> {
    #[cfg(test)]
    {
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(faults) = faults.get_mut(root) {
            if faults.fail_index_delete_remaining > 0 {
                faults.fail_index_delete_remaining -= 1;
                return Err(engine_err(
                    context,
                    std::io::Error::other("injected session index deletion failure"),
                ));
            }
        }
    }

    index_store(root).and_then(|store| {
        store
            .delete_session(session_id)
            .map_err(|err| engine_err(context, err))
    })
}

#[cfg(test)]
fn fail_fork_publication_after_row_if_requested(root: &Path) -> Result<(), PocketError> {
    let mut faults = SESSION_TEST_FAULTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(faults) = faults.get_mut(root) {
        if faults.fail_fork_publication_after_row_once {
            faults.fail_fork_publication_after_row_once = false;
            return Err(engine_err(
                "cannot publish fork index",
                std::io::Error::other("injected failure after fork row insertion"),
            ));
        }
    }
    Ok(())
}

fn indexed_session_model(root: &Path, session_id: &str) -> Result<String, PocketError> {
    let rows = index_store(root)?
        .list_sessions()
        .map_err(|e| engine_err("cannot list sessions", e))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    Ok(rows
        .into_iter()
        .find(|row| row.id == session_id)
        .map(|row| row.model)
        .unwrap_or_default())
}

fn transcript_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("transcripts").join(format!("{session_id}.jsonl"))
}

fn familiar_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("metadata")
        .join(format!("{session_id}.familiar.json"))
}

fn pending_forks_dir(root: &Path) -> PathBuf {
    root.join(".session-lifecycle").join("pending-forks")
}

fn pending_fork_marker(root: &Path, session_id: &str) -> PathBuf {
    pending_forks_dir(root).join(format!("{session_id}.pending"))
}

fn fork_staging_dir(root: &Path, session_id: &str) -> PathBuf {
    root.join(".fork-staging").join(session_id)
}

fn session_key(root: &Path, session_id: &str) -> SessionKey {
    SessionKey {
        root: root.to_path_buf(),
        session_id: session_id.to_string(),
    }
}

fn ensure_session_available(
    lifecycle: &SessionLifecycle,
    key: &SessionKey,
) -> Result<(), PocketError> {
    match lifecycle.sessions.get(key) {
        Some(SessionLifecycleState::Tombstoned) => Err(PocketError::Engine {
            message: format!("session {} was deleted", key.session_id),
        }),
        Some(SessionLifecycleState::PendingFork) => Err(PocketError::Engine {
            message: format!(
                "session {} is quarantined pending fork recovery",
                key.session_id
            ),
        }),
        _ => Ok(()),
    }
}

fn ensure_persistence_active(
    lifecycle: &SessionLifecycle,
    key: &SessionKey,
    generation: uuid::Uuid,
) -> Result<(), PocketError> {
    match lifecycle.sessions.get(key) {
        Some(SessionLifecycleState::Active(active)) if *active == generation => Ok(()),
        Some(SessionLifecycleState::Tombstoned) => Err(PocketError::Engine {
            message: format!("session {} was deleted", key.session_id),
        }),
        Some(SessionLifecycleState::Active(_))
        | Some(SessionLifecycleState::PendingFork)
        | None => Err(PocketError::Engine {
            message: format!(
                "session persistence handle for {} was invalidated",
                key.session_id
            ),
        }),
    }
}

fn sync_directory(path: &Path, context: &str) -> Result<(), PocketError> {
    #[cfg(test)]
    {
        DIRECTORY_SYNC_EVENTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(path.to_path_buf());
        let mut failures = DIRECTORY_SYNC_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(remaining) = failures.get_mut(path) {
            if *remaining > 0 {
                *remaining -= 1;
                return Err(engine_err(
                    context,
                    std::io::Error::other("injected directory sync failure"),
                ));
            }
        }
    }

    std::fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|err| engine_err(context, err))
}

fn sync_directory_if_present(path: &Path, context: &str) -> Result<(), PocketError> {
    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => sync_directory(path, context),
        Ok(_) => Err(PocketError::Engine {
            message: format!("{} is not a directory", path.display()),
        }),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(engine_err(context, err)),
    }
}

fn ensure_durable_directory(
    parent: &Path,
    directory: &Path,
    create_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    match std::fs::create_dir(directory) {
        Ok(()) => sync_directory(parent, sync_context),
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            let metadata = std::fs::metadata(directory)
                .map_err(|metadata_err| engine_err(create_context, metadata_err))?;
            if metadata.is_dir() {
                sync_directory(parent, sync_context)
            } else {
                Err(PocketError::Engine {
                    message: format!("{} is not a directory", directory.display()),
                })
            }
        }
        Err(err) => Err(engine_err(create_context, err)),
    }
}

fn remove_file_durably_if_present(
    path: &Path,
    directory: &Path,
    remove_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    match std::fs::remove_file(path) {
        Ok(()) => sync_directory(directory, sync_context),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            sync_directory_if_present(directory, sync_context)
        }
        Err(err) => Err(engine_err(remove_context, err)),
    }
}

fn remove_dir_durably_if_present(
    path: &Path,
    parent: &Path,
    remove_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    match std::fs::remove_dir(path) {
        Ok(()) => sync_directory(parent, sync_context),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            sync_directory_if_present(parent, sync_context)
        }
        Err(err) => Err(engine_err(remove_context, err)),
    }
}

fn remove_dir_all_durably_if_present(
    path: &Path,
    parent: &Path,
    remove_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    match std::fs::remove_dir_all(path) {
        Ok(()) => sync_directory(parent, sync_context),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            sync_directory_if_present(parent, sync_context)
        }
        Err(err) => Err(engine_err(remove_context, err)),
    }
}

fn remove_empty_fork_staging_root(root: &Path) -> Result<(), PocketError> {
    let stage_root = root.join(".fork-staging");
    match std::fs::remove_dir(&stage_root) {
        Ok(()) => sync_directory(root, "cannot sync fork staging root removal"),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            sync_directory(root, "cannot sync absent fork staging root")
        }
        Err(err) if err.kind() == std::io::ErrorKind::DirectoryNotEmpty => Ok(()),
        Err(err) => Err(engine_err("cannot remove fork staging root", err)),
    }
}

fn remove_fork_staging_artifacts(root: &Path, session_id: &str) -> Result<(), PocketError> {
    let stage_root = root.join(".fork-staging");
    remove_dir_all_durably_if_present(
        &fork_staging_dir(root, session_id),
        &stage_root,
        "cannot delete fork staging artifacts",
        "cannot sync fork staging artifact removal",
    )?;
    remove_empty_fork_staging_root(root)
}

fn write_new_file(path: &Path, bytes: &[u8], context: &str) -> Result<(), PocketError> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|err| engine_err(&format!("cannot create {context}"), err))?;
    file.write_all(bytes)
        .map_err(|err| engine_err(&format!("cannot write {context}"), err))?;
    file.sync_all()
        .map_err(|err| engine_err(&format!("cannot sync {context}"), err))
}

fn create_pending_fork_marker(root: &Path, session_id: &str) -> Result<(), PocketError> {
    let lifecycle_directory = root.join(".session-lifecycle");
    let directory = pending_forks_dir(root);
    ensure_durable_directory(
        root,
        &lifecycle_directory,
        "cannot create pending fork lifecycle directory",
        "cannot sync pending fork lifecycle directory creation",
    )?;
    ensure_durable_directory(
        &lifecycle_directory,
        &directory,
        "cannot create pending fork marker directory",
        "cannot sync pending fork marker directory creation",
    )?;
    let marker = pending_fork_marker(root, session_id);
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker)
        .map_err(|err| engine_err("cannot create pending fork marker", err))?;
    let create_result = (|| -> Result<(), PocketError> {
        file.sync_all()
            .map_err(|err| engine_err("cannot sync pending fork marker", err))?;
        sync_directory(&directory, "cannot sync pending fork marker directory")
    })();
    if let Err(create_err) = create_result {
        return match remove_file_durably_if_present(
            &marker,
            &directory,
            "cannot clean pending fork marker",
            "cannot sync pending fork marker cleanup",
        ) {
            Ok(()) => Err(create_err),
            Err(cleanup_err) => Err(PocketError::Engine {
                message: format!("{create_err}; cleanup also failed: {cleanup_err}"),
            }),
        };
    }
    Ok(())
}

fn ensure_pending_fork_marker(root: &Path, session_id: &str) -> Result<(), PocketError> {
    let marker = pending_fork_marker(root, session_id);
    match std::fs::metadata(&marker) {
        Ok(metadata) if metadata.is_file() => {
            std::fs::OpenOptions::new()
                .read(true)
                .open(&marker)
                .and_then(|file| file.sync_all())
                .map_err(|err| engine_err("cannot sync pending fork marker", err))?;
            sync_directory(
                &pending_forks_dir(root),
                "cannot sync pending fork marker directory",
            )
        }
        Ok(_) => Err(PocketError::Engine {
            message: format!("pending fork marker is not a file: {}", marker.display()),
        }),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            create_pending_fork_marker(root, session_id)
        }
        Err(err) => Err(engine_err("cannot inspect pending fork marker", err)),
    }
}

fn remove_pending_fork_marker(
    root: &Path,
    session_id: &str,
    missing_ok: bool,
) -> Result<(), PocketError> {
    let marker = pending_fork_marker(root, session_id);
    match std::fs::remove_file(&marker) {
        Ok(()) => {}
        Err(err) if missing_ok && err.kind() == std::io::ErrorKind::NotFound => {
            return sync_directory(
                &pending_forks_dir(root),
                "cannot sync absent pending fork marker",
            );
        }
        Err(err) => return Err(engine_err("cannot remove pending fork marker", err)),
    }
    sync_directory(
        &pending_forks_dir(root),
        "cannot sync pending fork marker removal",
    )
}

fn pending_fork_ids(root: &Path) -> Result<Vec<String>, PocketError> {
    let directory = pending_forks_dir(root);
    let entries = match std::fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(engine_err("cannot read pending fork markers", err)),
    };
    let mut session_ids = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|err| engine_err("cannot read pending fork marker", err))?;
        let file_type = entry
            .file_type()
            .map_err(|err| engine_err("cannot inspect pending fork marker", err))?;
        if !file_type.is_file() {
            return Err(PocketError::Engine {
                message: format!(
                    "pending fork marker is not a file: {}",
                    entry.path().display()
                ),
            });
        }
        let file_name = entry.file_name();
        let file_name = file_name.to_str().ok_or_else(|| PocketError::Engine {
            message: format!(
                "pending fork marker name is not valid UTF-8: {}",
                entry.path().display()
            ),
        })?;
        let session_id = file_name
            .strip_suffix(".pending")
            .ok_or_else(|| PocketError::Engine {
                message: format!("invalid pending fork marker name: {file_name}"),
            })?;
        validate_session_id(session_id).map_err(|err| PocketError::Engine {
            message: format!("invalid pending fork marker {file_name}: {err}"),
        })?;
        session_ids.push(session_id.to_string());
    }
    session_ids.sort();
    Ok(session_ids)
}

fn save_familiar_metadata_at_root(
    root: &Path,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    let destination = familiar_file(root, session_id);
    let Some(familiar) = familiar else {
        return remove_file_durably_if_present(
            &destination,
            &root.join("metadata"),
            "cannot delete familiar metadata",
            "cannot sync familiar metadata removal",
        );
    };

    let bytes = serde_json::to_vec(familiar)
        .map_err(|err| engine_err("cannot serialize familiar metadata", err))?;
    let metadata_dir = root.join("metadata");
    ensure_durable_directory(
        root,
        &metadata_dir,
        "cannot create metadata dir",
        "cannot sync metadata directory creation",
    )?;
    let temporary = metadata_dir.join(format!(
        ".{session_id}.familiar.{}.tmp",
        uuid::Uuid::new_v4()
    ));

    let write_result = (|| -> Result<(), PocketError> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|err| engine_err("cannot create temporary familiar metadata", err))?;
        file.write_all(&bytes)
            .map_err(|err| engine_err("cannot write temporary familiar metadata", err))?;
        file.sync_all()
            .map_err(|err| engine_err("cannot sync temporary familiar metadata", err))?;
        std::fs::rename(&temporary, &destination)
            .map_err(|err| engine_err("cannot install familiar metadata", err))?;
        sync_directory(
            &metadata_dir,
            "cannot sync installed familiar metadata directory",
        )
    })();

    if let Err(write_err) = write_result {
        return match remove_file_durably_if_present(
            &temporary,
            &metadata_dir,
            "cannot clean temporary familiar metadata",
            "cannot sync temporary familiar metadata cleanup",
        ) {
            Ok(()) => Err(write_err),
            Err(cleanup_err) => Err(PocketError::Engine {
                message: format!("{write_err}; rollback also failed: {cleanup_err}"),
            }),
        };
    }
    Ok(())
}

/// Atomically save a pinned familiar snapshot, or remove it when absent.
#[cfg(test)]
pub(crate) fn save_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    save_familiar_metadata_at_root(&root, session_id, familiar)
}

fn load_familiar_metadata_at_root(
    root: &Path,
    session_id: &str,
) -> Result<Option<FamiliarIdentity>, PocketError> {
    let Some(bytes) = familiar_metadata_bytes_at_root(root, session_id)? else {
        return Ok(None);
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|err| engine_err("cannot parse familiar metadata", err))
}

fn familiar_metadata_bytes_at_root(
    root: &Path,
    session_id: &str,
) -> Result<Option<Vec<u8>>, PocketError> {
    let bytes = match std::fs::read(familiar_file(root, session_id)) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(engine_err("cannot read familiar metadata", err)),
    };
    serde_json::from_slice::<FamiliarIdentity>(&bytes)
        .map_err(|err| engine_err("cannot parse familiar metadata", err))?;
    Ok(Some(bytes))
}

/// Load a pinned familiar snapshot. Missing metadata is backward-compatible.
#[cfg(test)]
pub(crate) fn load_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
) -> Result<Option<FamiliarIdentity>, PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    load_familiar_metadata_at_root(&root, session_id)
}

/// First line of the first user message, for the browser row.
fn derive_title(messages: &[Message]) -> String {
    messages
        .iter()
        .find(|m| matches!(m.role, Role::User))
        .map(|m| {
            m.get_all_text()
                .lines()
                .next()
                .unwrap_or_default()
                .trim()
                .chars()
                .take(60)
                .collect()
        })
        .unwrap_or_default()
}

/// Append-only persistence for one live session. All calls happen inside a
/// running turn (already serialized by the session's busy flag). Failures are
/// surfaced so the caller can decide to ignore them — a full disk must not
/// take the conversation down.
pub(crate) struct SessionPersistence {
    key: SessionKey,
    generation: uuid::Uuid,
    model: String,
    state: tokio::sync::Mutex<PersistState>,
}

struct PersistState {
    persisted: usize,
    last_uuid: Option<String>,
}

impl SessionPersistence {
    pub(crate) async fn create(
        storage_dir: &str,
        session_id: String,
        model: String,
        familiar: Option<&FamiliarIdentity>,
    ) -> Result<Self, PocketError> {
        validate_session_id(&session_id)?;
        let root = storage_root(storage_dir)?;
        let key = session_key(&root, &session_id);
        let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
        recover_pending_forks_unlocked(&root, &mut lifecycle)?;
        match lifecycle.sessions.get(&key).copied() {
            Some(SessionLifecycleState::Active(_)) => {
                return Err(PocketError::Engine {
                    message: format!("generated session id collision: {session_id}"),
                });
            }
            Some(SessionLifecycleState::Tombstoned) => {
                cleanup_session_artifacts(&root, &session_id).map_err(|err| {
                    PocketError::Engine {
                        message: format!("cannot clear deleted session before UUID reuse: {err}"),
                    }
                })?;
            }
            Some(SessionLifecycleState::PendingFork) => {
                return Err(PocketError::Engine {
                    message: format!("session {session_id} is quarantined pending fork recovery"),
                });
            }
            None => {}
        }
        save_familiar_metadata_at_root(&root, &session_id, familiar)?;
        let generation = uuid::Uuid::new_v4();
        lifecycle
            .sessions
            .insert(key.clone(), SessionLifecycleState::Active(generation));
        Ok(Self {
            key,
            generation,
            model,
            state: tokio::sync::Mutex::new(PersistState {
                persisted: 0,
                last_uuid: None,
            }),
        })
    }

    pub(crate) async fn resume(
        storage_dir: &str,
        session_id: String,
        model: String,
    ) -> Result<(Self, Vec<Message>, Option<FamiliarIdentity>), PocketError> {
        validate_session_id(&session_id)?;
        let root = storage_root(storage_dir)?;
        let key = session_key(&root, &session_id);
        let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
        recover_pending_forks_unlocked(&root, &mut lifecycle)?;
        ensure_session_available(&lifecycle, &key)?;
        let (messages, last_uuid) = load_session_messages_at_root(&root, &session_id).await?;
        let familiar = load_familiar_metadata_at_root(&root, &session_id)?;
        let generation = match lifecycle.sessions.get(&key).copied() {
            Some(SessionLifecycleState::Active(generation)) => generation,
            Some(SessionLifecycleState::Tombstoned) => {
                return Err(PocketError::Engine {
                    message: format!("session {session_id} was deleted"),
                });
            }
            Some(SessionLifecycleState::PendingFork) => {
                return Err(PocketError::Engine {
                    message: format!("session {session_id} is quarantined pending fork recovery"),
                });
            }
            None => {
                let generation = uuid::Uuid::new_v4();
                lifecycle
                    .sessions
                    .insert(key.clone(), SessionLifecycleState::Active(generation));
                generation
            }
        };
        let persistence = Self {
            key,
            generation,
            model,
            state: tokio::sync::Mutex::new(PersistState {
                persisted: messages.len(),
                last_uuid,
            }),
        };
        Ok((persistence, messages, familiar))
    }

    /// Persist every message beyond the already-persisted prefix: append
    /// JSONL entries and mirror text into the SQLite index.
    pub(crate) async fn persist_new(&self, messages: &[Message]) -> Result<(), PocketError> {
        let lifecycle = SESSION_LIFECYCLE_LOCK.read().await;
        ensure_persistence_active(&lifecycle, &self.key, self.generation)?;
        let mut state = self.state.lock().await;
        if messages.len() <= state.persisted {
            return Ok(());
        }

        let path = transcript_file(&self.key.root, &self.key.session_id);
        let store = index_store(&self.key.root)?;
        store
            .save_session(
                &self.key.session_id,
                Some(&derive_title(messages)),
                &self.model,
            )
            .map_err(|e| engine_err("cannot index session", e))?;

        for message in &messages[state.persisted..] {
            let uuid = uuid::Uuid::new_v4().to_string();
            let entry = build_entry(
                message.clone(),
                &uuid,
                state.last_uuid.as_deref(),
                &self.key.session_id,
            );
            write_transcript_entry(&path, &entry)
                .await
                .map_err(|e| engine_err("cannot write transcript", e))?;
            store
                .save_message(
                    &self.key.session_id,
                    &uuid,
                    role_str(&message.role),
                    &message.get_all_text(),
                    None,
                )
                .map_err(|e| engine_err("cannot index message", e))?;
            state.last_uuid = Some(uuid);
            state.persisted += 1;
        }
        Ok(())
    }
}

fn role_str(role: &Role) -> &'static str {
    match role {
        Role::Assistant => "assistant",
        _ => "user",
    }
}

fn build_entry(
    message: Message,
    uuid: &str,
    parent: Option<&str>,
    session_id: &str,
) -> TranscriptEntry {
    match message.role {
        Role::Assistant => make_assistant_entry(message, uuid, parent, session_id, ""),
        _ => make_user_entry(message, uuid, parent, session_id, ""),
    }
}

async fn load_session_messages_at_root(
    root: &Path,
    session_id: &str,
) -> Result<(Vec<Message>, Option<String>), PocketError> {
    let path = transcript_file(root, session_id);
    if !path.exists() {
        return Err(PocketError::Engine {
            message: format!("no stored session {session_id}"),
        });
    }
    let entries = load_transcript(&path)
        .await
        .map_err(|e| engine_err("cannot load transcript", e))?;
    let last_uuid = entries
        .iter()
        .rev()
        .find_map(|e| e.uuid().map(str::to_string));
    Ok((messages_from_transcript(&entries), last_uuid))
}

/// Newest-first summaries for the browser.
pub async fn list_sessions(storage_dir: &str) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let root = storage_root(storage_dir)?;
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_pending_forks_unlocked(&root, &mut lifecycle)?;
    list_sessions_unlocked(&root, &lifecycle)
}

fn list_sessions_unlocked(
    root: &Path,
    lifecycle: &SessionLifecycle,
) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let store = index_store(root)?;
    let rows = store
        .list_sessions()
        .map_err(|e| engine_err("cannot list sessions", e))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    rows.into_iter()
        .filter(|session| {
            !matches!(
                lifecycle.sessions.get(&session_key(root, &session.id)),
                Some(SessionLifecycleState::Tombstoned | SessionLifecycleState::PendingFork)
            )
        })
        .map(|s| {
            let familiar = load_familiar_metadata_at_root(root, &s.id)?;
            Ok(ChatSessionSummary {
                session_id: s.id,
                title: s.title.unwrap_or_default(),
                model: s.model,
                created_at: s.created_at,
                updated_at: s.updated_at,
                message_count: s.message_count,
                familiar,
            })
        })
        .collect()
}

/// Drop a session from the index and delete its transcript file.
pub async fn delete_session(storage_dir: &str, session_id: &str) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let key = session_key(&root, session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    let in_memory_pending = matches!(
        lifecycle.sessions.get(&key),
        Some(SessionLifecycleState::PendingFork)
    );
    let mut is_pending = pending_fork_marker(&root, session_id)
        .try_exists()
        .map_err(|err| engine_err("cannot inspect pending fork marker", err))?;
    if in_memory_pending && !is_pending {
        ensure_pending_fork_marker(&root, session_id)?;
        is_pending = true;
    }
    lifecycle.sessions.insert(
        key.clone(),
        if is_pending {
            SessionLifecycleState::PendingFork
        } else {
            SessionLifecycleState::Tombstoned
        },
    );
    match cleanup_session_artifacts(&root, session_id) {
        Ok(()) => {
            lifecycle
                .sessions
                .insert(key, SessionLifecycleState::Tombstoned);
            Ok(())
        }
        Err(err) => Err(err),
    }
}

fn cleanup_session_artifacts(root: &Path, session_id: &str) -> Result<(), PocketError> {
    delete_index_session(root, session_id, "cannot delete session index")?;

    let marker_exists = pending_fork_marker(root, session_id)
        .try_exists()
        .map_err(|err| engine_err("cannot inspect pending fork marker", err))?;
    let mut errors = Vec::new();
    if let Err(err) = remove_file_durably_if_present(
        &transcript_file(root, session_id),
        &root.join("transcripts"),
        "cannot delete transcript",
        "cannot sync transcript removal",
    ) {
        errors.push(err.to_string());
    }
    if let Err(err) = save_familiar_metadata_at_root(root, session_id, None) {
        errors.push(err.to_string());
    }
    if let Err(err) = remove_fork_staging_artifacts(root, session_id) {
        errors.push(err.to_string());
    }
    if errors.is_empty() && marker_exists {
        if let Err(err) = remove_pending_fork_marker(root, session_id, true) {
            errors.push(err.to_string());
            if let Err(restore_err) = ensure_pending_fork_marker(root, session_id) {
                errors.push(restore_err.to_string());
            }
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(PocketError::Engine {
            message: format!("cannot delete all session artifacts: {}", errors.join("; ")),
        })
    }
}

fn recover_pending_forks_unlocked(
    root: &Path,
    lifecycle: &mut SessionLifecycle,
) -> Result<(), PocketError> {
    let pending_ids = pending_fork_ids(root)?;
    if let Some(key) = lifecycle.sessions.keys().find(|key| {
        key.root == root
            && matches!(
                lifecycle.sessions.get(*key),
                Some(SessionLifecycleState::PendingFork)
            )
            && !pending_ids.contains(&key.session_id)
    }) {
        return Err(PocketError::Engine {
            message: format!(
                "cannot recover pending fork {}: persistent marker is missing",
                key.session_id
            ),
        });
    }

    for session_id in &pending_ids {
        let key = session_key(root, session_id);
        lifecycle
            .sessions
            .insert(key.clone(), SessionLifecycleState::PendingFork);
        if let Err(err) = cleanup_session_artifacts(root, session_id) {
            return Err(PocketError::Engine {
                message: format!("cannot recover pending fork {session_id}: {err}"),
            });
        }
        if matches!(
            lifecycle.sessions.get(&key),
            Some(SessionLifecycleState::PendingFork)
        ) {
            lifecycle.sessions.remove(&key);
        }
    }
    Ok(())
}

/// Copy a session's transcript under a fresh id at its current head.
/// Returns the new session id.
pub async fn fork_session(storage_dir: &str, session_id: &str) -> Result<String, PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let key = session_key(&root, session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_pending_forks_unlocked(&root, &mut lifecycle)?;
    ensure_session_available(&lifecycle, &key)?;
    fork_session_unlocked(&root, session_id, &mut lifecycle, None).await
}

#[cfg(test)]
struct ForkStagePause {
    staged: tokio::sync::oneshot::Sender<()>,
    resume: tokio::sync::oneshot::Receiver<()>,
}

#[cfg(test)]
async fn fork_session_with_stage_pause(
    storage_dir: &str,
    session_id: &str,
    stage_pause: ForkStagePause,
) -> Result<String, PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let key = session_key(&root, session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_pending_forks_unlocked(&root, &mut lifecycle)?;
    ensure_session_available(&lifecycle, &key)?;
    fork_session_unlocked(&root, session_id, &mut lifecycle, Some(stage_pause)).await
}

struct ForkStage {
    root: PathBuf,
    session_id: String,
    directory: PathBuf,
    transcript: PathBuf,
    metadata: Option<PathBuf>,
    published_transcript: Option<PathBuf>,
    published_metadata: Option<PathBuf>,
    pending_marker: Option<PathBuf>,
    index_may_exist: bool,
    staging_may_exist: bool,
    armed: bool,
}

impl ForkStage {
    fn begin(root: &Path, new_id: &str) -> Result<Self, PocketError> {
        let directory = fork_staging_dir(root, new_id);
        create_pending_fork_marker(root, new_id)?;
        Ok(Self {
            root: root.to_path_buf(),
            session_id: new_id.to_string(),
            transcript: directory.join(format!("{new_id}.jsonl")),
            metadata: None,
            directory,
            published_transcript: None,
            published_metadata: None,
            pending_marker: Some(pending_fork_marker(root, new_id)),
            index_may_exist: false,
            staging_may_exist: false,
            armed: true,
        })
    }

    fn create_staging_directory(&mut self) -> Result<(), PocketError> {
        let stage_root = self.directory.parent().ok_or_else(|| PocketError::Engine {
            message: format!(
                "fork staging directory has no parent: {}",
                self.directory.display()
            ),
        })?;
        ensure_durable_directory(
            &self.root,
            stage_root,
            "cannot create fork staging root",
            "cannot sync fork staging root creation",
        )?;
        self.staging_may_exist = true;
        std::fs::create_dir(&self.directory)
            .map_err(|err| engine_err("cannot create fork staging directory", err))?;
        sync_directory(stage_root, "cannot sync fork staging directory creation")
    }

    #[cfg(test)]
    fn create(root: &Path, new_id: &str) -> Result<Self, PocketError> {
        let mut stage = Self::begin(root, new_id)?;
        if let Err(err) = stage.create_staging_directory() {
            return Err(fork_stage_error(
                "cannot initialize fork staging",
                err,
                &mut stage,
            ));
        }
        Ok(stage)
    }

    fn stage_metadata(&mut self, bytes: &[u8]) -> Result<(), PocketError> {
        self.stage_metadata_with(bytes, write_new_file)
    }

    fn stage_metadata_with(
        &mut self,
        bytes: &[u8],
        write: impl FnOnce(&Path, &[u8], &str) -> Result<(), PocketError>,
    ) -> Result<(), PocketError> {
        let metadata = self
            .directory
            .join(format!("{}.familiar.json", self.session_id));
        self.metadata = Some(metadata.clone());
        write(&metadata, bytes, "staged fork familiar metadata")
    }

    fn remove_pending_marker_for_commit(&mut self) -> Result<(), PocketError> {
        remove_pending_fork_marker(&self.root, &self.session_id, false)?;
        self.pending_marker = None;
        Ok(())
    }

    fn cleanup(&mut self) -> Result<(), PocketError> {
        if !self.armed {
            return Ok(());
        }
        let mut errors = Vec::new();
        if self.index_may_exist {
            if self.pending_marker.is_some() {
                if let Err(err) = ensure_pending_fork_marker(&self.root, &self.session_id) {
                    errors.push(err.to_string());
                }
            }
            match delete_index_session(&self.root, &self.session_id, "cannot clean fork index") {
                Ok(()) => self.index_may_exist = false,
                Err(err) => {
                    errors.push(err.to_string());
                    self.armed = false;
                    return Err(PocketError::Engine {
                        message: format!(
                            "cannot clean fork staging artifacts: {}",
                            errors.join("; ")
                        ),
                    });
                }
            }
        }
        for (path, directory, remove_context, sync_context) in [
            (
                self.published_metadata.take(),
                self.root.join("metadata"),
                "cannot clean published fork metadata",
                "cannot sync published fork metadata cleanup",
            ),
            (
                self.published_transcript.take(),
                self.root.join("transcripts"),
                "cannot clean published fork transcript",
                "cannot sync published fork transcript cleanup",
            ),
        ] {
            if let Some(path) = path {
                if let Err(err) =
                    remove_file_durably_if_present(&path, &directory, remove_context, sync_context)
                {
                    errors.push(err.to_string());
                }
            }
        }
        self.metadata = None;
        if self.staging_may_exist {
            if let Err(err) = remove_fork_staging_artifacts(&self.root, &self.session_id) {
                errors.push(err.to_string());
            } else {
                self.staging_may_exist = false;
            }
        } else if let Err(err) = remove_empty_fork_staging_root(&self.root) {
            errors.push(err.to_string());
        }
        if errors.is_empty() && self.pending_marker.is_some() {
            match remove_pending_fork_marker(&self.root, &self.session_id, true) {
                Ok(()) => self.pending_marker = None,
                Err(err) => {
                    errors.push(err.to_string());
                    if let Err(restore_err) =
                        ensure_pending_fork_marker(&self.root, &self.session_id)
                    {
                        errors.push(restore_err.to_string());
                    }
                }
            }
        }
        if errors.is_empty() {
            self.armed = false;
            Ok(())
        } else {
            if self.pending_marker.is_some() {
                self.armed = false;
            }
            Err(PocketError::Engine {
                message: format!("cannot clean fork staging artifacts: {}", errors.join("; ")),
            })
        }
    }

    fn remove_empty_staging_dirs(&self) -> Result<(), PocketError> {
        let stage_root = self.directory.parent().ok_or_else(|| PocketError::Engine {
            message: format!(
                "fork staging directory has no parent: {}",
                self.directory.display()
            ),
        })?;
        remove_dir_durably_if_present(
            &self.directory,
            stage_root,
            "cannot remove empty fork staging dir",
            "cannot sync empty fork staging directory removal",
        )?;
        remove_empty_fork_staging_root(&self.root)
    }
}

impl Drop for ForkStage {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

fn fork_stage_error(
    context: &str,
    err: impl std::fmt::Display,
    stage: &mut ForkStage,
) -> PocketError {
    let primary = format!("{context}: {err}");
    match stage.cleanup() {
        Ok(()) => PocketError::Engine { message: primary },
        Err(cleanup_err) => PocketError::Engine {
            message: format!("{primary}; cleanup also failed: {cleanup_err}"),
        },
    }
}

fn fork_publication_error(
    context: &str,
    err: impl std::fmt::Display,
    stage: &mut ForkStage,
    lifecycle: &mut SessionLifecycle,
    key: &SessionKey,
) -> PocketError {
    let primary = format!("{context}: {err}");
    match stage.cleanup() {
        Ok(()) => {
            if matches!(
                lifecycle.sessions.get(key),
                Some(SessionLifecycleState::PendingFork)
            ) {
                lifecycle.sessions.remove(key);
            }
            PocketError::Engine { message: primary }
        }
        Err(cleanup_err) => {
            lifecycle
                .sessions
                .insert(key.clone(), SessionLifecycleState::PendingFork);
            PocketError::Engine {
                message: format!("{primary}; cleanup also failed: {cleanup_err}"),
            }
        }
    }
}

async fn fork_session_unlocked(
    root: &Path,
    session_id: &str,
    lifecycle: &mut SessionLifecycle,
    #[cfg(test)] mut stage_pause: Option<ForkStagePause>,
    #[cfg(not(test))] _stage_pause: Option<()>,
) -> Result<String, PocketError> {
    let (messages, _) = load_session_messages_at_root(root, session_id).await?;
    if messages.is_empty() {
        return Err(PocketError::Engine {
            message: format!("session {session_id} has no messages to fork"),
        });
    }

    // Model comes from the source's index row; the transcript doesn't carry it.
    let model = indexed_session_model(root, session_id)?;

    let new_id = uuid::Uuid::new_v4().to_string();
    let key = session_key(root, &new_id);
    if matches!(
        lifecycle.sessions.get(&key),
        Some(SessionLifecycleState::Active(_) | SessionLifecycleState::PendingFork)
    ) {
        return Err(PocketError::Engine {
            message: format!("generated fork session id collision: {new_id}"),
        });
    }
    if matches!(
        lifecycle.sessions.get(&key),
        Some(SessionLifecycleState::Tombstoned)
    ) {
        cleanup_session_artifacts(root, &new_id).map_err(|err| PocketError::Engine {
            message: format!("cannot clear deleted fork UUID collision: {err}"),
        })?;
        lifecycle.sessions.remove(&key);
    }

    let familiar_bytes = familiar_metadata_bytes_at_root(root, session_id)?;
    let mut stage = ForkStage::begin(root, &new_id)?;
    if let Err(err) = stage.create_staging_directory() {
        return Err(fork_stage_error(
            "cannot initialize fork staging",
            err,
            &mut stage,
        ));
    }
    if let Some(bytes) = familiar_bytes {
        if let Err(err) = stage.stage_metadata(&bytes) {
            return Err(fork_stage_error(
                "cannot stage fork familiar metadata",
                err,
                &mut stage,
            ));
        }
    }

    let mut parent: Option<String> = None;
    let mut indexed_messages = Vec::with_capacity(messages.len());
    for message in &messages {
        let uuid = uuid::Uuid::new_v4().to_string();
        let entry = build_entry(message.clone(), &uuid, parent.as_deref(), &new_id);
        if let Err(err) = write_transcript_entry(&stage.transcript, &entry).await {
            return Err(fork_stage_error(
                "cannot stage fork transcript",
                err,
                &mut stage,
            ));
        }
        indexed_messages.push((uuid.clone(), message));
        parent = Some(uuid);

        #[cfg(test)]
        if let Some(stage_pause) = stage_pause.take() {
            let _ = stage_pause.staged.send(());
            let _ = stage_pause.resume.await;
        }
    }

    if let Err(err) = std::fs::OpenOptions::new()
        .read(true)
        .open(&stage.transcript)
        .and_then(|file| file.sync_all())
    {
        return Err(fork_stage_error(
            "cannot sync staged fork transcript",
            err,
            &mut stage,
        ));
    }

    let transcript_destination = transcript_file(root, &new_id);
    let transcript_directory = root.join("transcripts");
    ensure_durable_directory(
        root,
        &transcript_directory,
        "cannot create transcript dir",
        "cannot sync transcript directory creation",
    )
    .map_err(|err| fork_stage_error("cannot prepare transcript dir", err, &mut stage))?;
    std::fs::rename(&stage.transcript, &transcript_destination)
        .map_err(|err| fork_stage_error("cannot publish fork transcript", err, &mut stage))?;
    stage.published_transcript = Some(transcript_destination);
    sync_directory(
        &transcript_directory,
        "cannot sync published fork transcript directory",
    )
    .map_err(|err| {
        fork_stage_error(
            "cannot make published fork transcript durable",
            err,
            &mut stage,
        )
    })?;

    if let Some(metadata) = stage.metadata.clone() {
        let metadata_destination = familiar_file(root, &new_id);
        let metadata_directory = root.join("metadata");
        ensure_durable_directory(
            root,
            &metadata_directory,
            "cannot create metadata dir",
            "cannot sync metadata directory creation",
        )
        .map_err(|err| fork_stage_error("cannot prepare metadata dir", err, &mut stage))?;
        std::fs::rename(&metadata, &metadata_destination)
            .map_err(|err| fork_stage_error("cannot publish fork metadata", err, &mut stage))?;
        stage.metadata = None;
        stage.published_metadata = Some(metadata_destination);
        sync_directory(
            &metadata_directory,
            "cannot sync published fork metadata directory",
        )
        .map_err(|err| {
            fork_stage_error(
                "cannot make published fork metadata durable",
                err,
                &mut stage,
            )
        })?;
    }
    stage
        .remove_empty_staging_dirs()
        .map_err(|err| fork_stage_error("cannot finalize fork staging", err, &mut stage))?;

    lifecycle
        .sessions
        .insert(key.clone(), SessionLifecycleState::PendingFork);

    let store = match index_store(root) {
        Ok(store) => store,
        Err(err) => {
            return Err(fork_publication_error(
                "cannot open fork index",
                err,
                &mut stage,
                lifecycle,
                &key,
            ));
        }
    };
    stage.index_may_exist = true;
    if let Err(err) = store.save_session(&new_id, Some(&derive_title(&messages)), &model) {
        return Err(fork_publication_error(
            "cannot publish fork index",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    #[cfg(test)]
    if let Err(err) = fail_fork_publication_after_row_if_requested(root) {
        return Err(fork_publication_error(
            "cannot publish fork index",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    for (uuid, message) in indexed_messages {
        if let Err(err) = store.save_message(
            &new_id,
            &uuid,
            role_str(&message.role),
            &message.get_all_text(),
            None,
        ) {
            return Err(fork_publication_error(
                "cannot publish fork message index",
                err,
                &mut stage,
                lifecycle,
                &key,
            ));
        }
    }
    if let Err(err) = stage.remove_pending_marker_for_commit() {
        return Err(fork_publication_error(
            "cannot commit fork publication",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    lifecycle
        .sessions
        .insert(key, SessionLifecycleState::Active(uuid::Uuid::new_v4()));
    stage.published_transcript = None;
    stage.published_metadata = None;
    stage.index_may_exist = false;
    stage.armed = false;
    Ok(new_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_storage(label: &str) -> PathBuf {
        let dir = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("session-tests")
            .join(format!("{label}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn familiar() -> crate::remote::FamiliarIdentity {
        crate::remote::FamiliarIdentity {
            id: "familiar-1".to_string(),
            display_name: "Morgana".to_string(),
            emoji: Some("moon".to_string()),
            role: Some("repository guide".to_string()),
        }
    }

    fn configure_session_faults(
        root: &Path,
        fail_fork_publication_after_row_once: bool,
        fail_index_delete_remaining: usize,
    ) {
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                root.to_path_buf(),
                SessionTestFaults {
                    fail_fork_publication_after_row_once,
                    fail_index_delete_remaining,
                },
            );
    }

    fn directory_syncs_for(root: &Path) -> Vec<PathBuf> {
        let metadata = root.join("metadata");
        DIRECTORY_SYNC_EVENTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|path| path.as_path() == root || path.as_path() == metadata)
            .cloned()
            .collect()
    }

    fn fail_directory_sync(path: &Path, count: usize) {
        DIRECTORY_SYNC_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(path.to_path_buf(), count);
    }

    async fn clear_module_state_for_root(root: &Path) {
        SESSION_LIFECYCLE_LOCK
            .write()
            .await
            .sessions
            .retain(|key, _| key.root != root);
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(root);
    }

    fn indexed_fork_id(root: &Path, source_id: &str) -> String {
        index_store(root)
            .unwrap()
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|row| row.id != source_id)
            .unwrap()
            .id
    }

    #[test]
    fn session_id_validation_rejects_path_shapes() {
        assert!(validate_session_id(&uuid::Uuid::new_v4().to_string()).is_ok());
        for bad in ["", ".", "..", "../evil", "a/b", "a\\b", "x.jsonl"] {
            assert!(validate_session_id(bad).is_err(), "accepted {bad:?}");
        }
    }

    #[test]
    fn title_comes_from_first_user_line_truncated() {
        let long = "x".repeat(100);
        let messages = vec![
            Message::assistant("ignored"),
            Message::user(format!("{long}\nrest")),
        ];
        let title = derive_title(&messages);
        assert_eq!(title.chars().count(), 60);
        assert!(!title.contains('\n'));
        assert_eq!(derive_title(&[]), "");
    }

    #[tokio::test]
    async fn list_on_fresh_dir_is_empty_and_relative_dir_errors() {
        let dir = test_storage("list");
        assert!(list_sessions(&dir.display().to_string())
            .await
            .unwrap()
            .is_empty());
        assert!(list_sessions("relative/dir").await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn fork_of_unknown_session_errors() {
        let dir = test_storage("fork");
        let err = fork_session(
            &dir.display().to_string(),
            &uuid::Uuid::new_v4().to_string(),
        )
        .await;
        assert!(err.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn familiar_sidecar_saves_loads_removes_and_rejects_malformed_json() {
        let storage = test_storage("metadata");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let identity = familiar();

        save_familiar_metadata(&storage_str, &session_id, Some(&identity)).unwrap();
        assert_eq!(
            load_familiar_metadata(&storage_str, &session_id).unwrap(),
            Some(identity.clone())
        );

        save_familiar_metadata(&storage_str, &session_id, None).unwrap();
        assert_eq!(
            load_familiar_metadata(&storage_str, &session_id).unwrap(),
            None
        );

        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        std::fs::write(
            storage
                .join("metadata")
                .join(format!("{session_id}.familiar.json")),
            b"{not-json",
        )
        .unwrap();
        let err = load_familiar_metadata(&storage_str, &session_id).unwrap_err();
        assert!(err.to_string().contains("cannot parse familiar metadata"));
        assert!(load_familiar_metadata(&storage_str, "../invalid").is_err());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn familiar_save_and_removal_sync_required_directories_in_order() {
        let storage = test_storage("metadata-directory-sync");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();

        SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();

        assert_eq!(
            directory_syncs_for(&storage),
            [storage.clone(), storage.join("metadata")]
        );

        save_familiar_metadata_at_root(&storage, &session_id, Some(&familiar())).unwrap();
        assert_eq!(
            directory_syncs_for(&storage),
            [
                storage.clone(),
                storage.join("metadata"),
                storage.clone(),
                storage.join("metadata")
            ]
        );

        save_familiar_metadata_at_root(&storage, &session_id, None).unwrap();
        assert_eq!(
            directory_syncs_for(&storage),
            [
                storage.clone(),
                storage.join("metadata"),
                storage.clone(),
                storage.join("metadata"),
                storage.join("metadata")
            ]
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn list_sessions_includes_pinned_familiar_and_old_sessions_use_none() {
        let storage = test_storage("list-metadata");
        let storage_str = storage.display().to_string();
        let pinned_id = uuid::Uuid::new_v4().to_string();
        let old_id = uuid::Uuid::new_v4().to_string();
        let store = index_store(&storage).unwrap();
        store
            .save_session(&pinned_id, Some("Pinned"), "model")
            .unwrap();
        store.save_session(&old_id, Some("Old"), "model").unwrap();
        let identity = familiar();
        save_familiar_metadata(&storage_str, &pinned_id, Some(&identity)).unwrap();

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(
            listed
                .iter()
                .find(|row| row.session_id == pinned_id)
                .unwrap()
                .familiar,
            Some(identity)
        );
        assert_eq!(
            listed
                .iter()
                .find(|row| row.session_id == old_id)
                .unwrap()
                .familiar,
            None
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn malformed_familiar_sidecar_fails_the_whole_session_list() {
        let storage = test_storage("list-malformed");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Broken"), "model")
            .unwrap();
        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        std::fs::write(familiar_file(&storage, &session_id), b"not-json").unwrap();

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("malformed familiar metadata must fail the list"),
            Err(err) => err,
        };
        assert!(err.to_string().contains("cannot parse familiar metadata"));

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn list_sessions_rejects_path_shaped_index_id_before_sidecar_access() {
        let storage = test_storage("list-invalid-index-id");
        let storage_str = storage.display().to_string();
        let sentinel_name = format!("escaped-{}", uuid::Uuid::new_v4());
        let malformed_id = format!("../../{sentinel_name}");
        index_store(&storage)
            .unwrap()
            .save_session(&malformed_id, Some("Corrupt"), "model")
            .unwrap();

        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        let escaped_sidecar = storage
            .parent()
            .unwrap()
            .join(format!("{sentinel_name}.familiar.json"));
        let sentinel = b"not familiar metadata";
        std::fs::write(&escaped_sidecar, sentinel).unwrap();
        assert_eq!(
            std::fs::canonicalize(familiar_file(&storage, &malformed_id)).unwrap(),
            std::fs::canonicalize(&escaped_sidecar).unwrap()
        );

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("path-shaped indexed session id must fail the list"),
            Err(err) => err,
        };
        match err {
            PocketError::Engine { message } => {
                assert_eq!(message, format!("invalid session id: {malformed_id}"));
            }
            other => panic!("unexpected error: {other}"),
        }
        assert_eq!(std::fs::read(&escaped_sidecar).unwrap(), sentinel);
        assert!(!storage.join("transcripts").exists());
        assert!(!storage.join(".fork-staging").exists());
        assert!(!storage.join(".session-lifecycle").exists());

        std::fs::remove_file(escaped_sidecar).unwrap();
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn deleted_session_permanently_rejects_a_surviving_persistence_handle() {
        let storage = test_storage("delete-invalidates-persistence");
        let storage_str = storage.display().to_string();
        let storage_alias = storage
            .join("..")
            .join(storage.file_name().unwrap())
            .display()
            .to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence = SessionPersistence::create(
            &storage_alias,
            session_id.clone(),
            "model".to_string(),
            None,
        )
        .await
        .unwrap();
        persistence
            .persist_new(&[Message::user("before deletion")])
            .await
            .unwrap();
        save_familiar_metadata(&storage_str, &session_id, Some(&familiar())).unwrap();

        delete_session(&storage_str, &session_id).await.unwrap();

        let err = persistence
            .persist_new(&[
                Message::user("before deletion"),
                Message::assistant("after deletion"),
            ])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("was deleted"));
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!familiar_file(&storage, &session_id).exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn uuid_reuse_clears_tombstone_without_revalidating_old_handles() {
        let storage = test_storage("delete-uuid-reuse");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let original = SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "old-model".to_string(),
            None,
        )
        .await
        .unwrap();
        original
            .persist_new(&[Message::user("old message")])
            .await
            .unwrap();
        delete_session(&storage_str, &session_id).await.unwrap();

        let replacement = SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "new-model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        replacement
            .persist_new(&[Message::user("replacement message")])
            .await
            .unwrap();

        let err = original
            .persist_new(&[
                Message::user("old message"),
                Message::assistant("stale append"),
            ])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("was invalidated"));

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, session_id);
        assert_eq!(listed[0].title, "replacement message");
        assert_eq!(listed[0].model, "new-model");
        assert_eq!(listed[0].message_count, 1);
        assert_eq!(listed[0].familiar, Some(familiar()));
        let (messages, _) = load_session_messages_at_root(&storage, &session_id)
            .await
            .unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].get_all_text(), "replacement message");

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn fork_copies_familiar_and_delete_removes_its_sidecar() {
        let storage = test_storage("fork-metadata");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[
                Message::user("seeded source"),
                Message::assistant("source response"),
            ])
            .await
            .unwrap();
        let identity = familiar();
        save_familiar_metadata(&storage_str, &source_id, Some(&identity)).unwrap();

        let fork_id = fork_session(&storage_str, &source_id).await.unwrap();
        assert_eq!(
            load_familiar_metadata(&storage_str, &fork_id).unwrap(),
            Some(identity)
        );
        assert_eq!(
            std::fs::read(familiar_file(&storage, &source_id)).unwrap(),
            std::fs::read(familiar_file(&storage, &fork_id)).unwrap()
        );
        let entries = load_transcript(&transcript_file(&storage, &fork_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 2);
        let first_uuid = match &entries[0] {
            TranscriptEntry::User(message) => {
                assert_eq!(message.session_id, fork_id);
                assert!(message.parent_uuid.is_none());
                message.uuid.clone().unwrap()
            }
            _ => panic!("first fork entry must be the source user message"),
        };
        match &entries[1] {
            TranscriptEntry::Assistant(message) => {
                assert_eq!(message.session_id, fork_id);
                assert_eq!(message.parent_uuid.as_deref(), Some(first_uuid.as_str()));
            }
            _ => panic!("second fork entry must be the source assistant message"),
        }
        let fork_sidecar = storage
            .join("metadata")
            .join(format!("{fork_id}.familiar.json"));
        assert!(fork_sidecar.exists());

        delete_session(&storage_str, &fork_id).await.unwrap();
        assert!(!fork_sidecar.exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn failed_fork_publication_is_quarantined_until_restart_recovery() {
        let storage = test_storage("fork-pending-recovery");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source = SessionPersistence::create(
            &storage_str,
            source_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        source
            .persist_new(&[
                Message::user("source message"),
                Message::assistant("source response"),
            ])
            .await
            .unwrap();

        configure_session_faults(&storage, true, 1);
        let err = fork_session(&storage_str, &source_id).await.unwrap_err();
        assert!(err
            .to_string()
            .contains("injected failure after fork row insertion"));
        assert!(err
            .to_string()
            .contains("injected session index deletion failure"));

        let fork_id = indexed_fork_id(&storage, &source_id);
        let marker = storage
            .join(".session-lifecycle")
            .join("pending-forks")
            .join(format!("{fork_id}.pending"));
        assert!(transcript_file(&storage, &fork_id).exists());
        assert!(familiar_file(&storage, &fork_id).exists());
        assert!(marker.exists());

        let stale_stage = storage.join(".fork-staging").join(&fork_id);
        std::fs::create_dir_all(&stale_stage).unwrap();
        std::fs::write(stale_stage.join("stale"), b"stale").unwrap();

        clear_module_state_for_root(&storage).await;
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, source_id);
        assert!(!index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .iter()
            .any(|row| row.id == fork_id));
        assert!(!transcript_file(&storage, &fork_id).exists());
        assert!(!familiar_file(&storage, &fork_id).exists());
        assert!(!marker.exists());
        assert!(!stale_stage.exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn repeated_pending_fork_recovery_failure_preserves_identity_artifacts() {
        let storage = test_storage("fork-pending-recovery-repeat");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source = SessionPersistence::create(
            &storage_str,
            source_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        source
            .persist_new(&[Message::user("source message")])
            .await
            .unwrap();

        configure_session_faults(&storage, true, 1);
        fork_session(&storage_str, &source_id).await.unwrap_err();
        let fork_id = indexed_fork_id(&storage, &source_id);
        let marker = storage
            .join(".session-lifecycle")
            .join("pending-forks")
            .join(format!("{fork_id}.pending"));
        let stale_stage = fork_staging_dir(&storage, &fork_id);
        std::fs::create_dir_all(&stale_stage).unwrap();
        std::fs::write(stale_stage.join("stale"), b"stale").unwrap();

        clear_module_state_for_root(&storage).await;
        configure_session_faults(&storage, false, 2);
        for _ in 0..2 {
            let err = match list_sessions(&storage_str).await {
                Ok(_) => panic!("pending-fork recovery failure must fail the list"),
                Err(err) => err,
            };
            assert!(err
                .to_string()
                .contains("injected session index deletion failure"));
            assert!(index_store(&storage)
                .unwrap()
                .list_sessions()
                .unwrap()
                .iter()
                .any(|row| row.id == fork_id));
            assert!(transcript_file(&storage, &fork_id).exists());
            assert!(familiar_file(&storage, &fork_id).exists());
            assert!(marker.exists());
            assert!(stale_stage.exists());
        }

        clear_module_state_for_root(&storage).await;
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, source_id);
        assert!(!storage.join(".fork-staging").exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn restart_recovery_removes_unindexed_artifacts_seeded_during_fork_staging() {
        let storage = test_storage("fork-marker-stage-recovery");
        let storage_str = storage.display().to_string();
        let fork_id = uuid::Uuid::new_v4().to_string();
        let stage = fork_staging_dir(&storage, &fork_id);

        create_pending_fork_marker(&storage, &fork_id).unwrap();
        std::fs::create_dir_all(&stage).unwrap();
        std::fs::write(stage.join(format!("{fork_id}.jsonl")), b"staged transcript").unwrap();
        std::fs::write(
            stage.join(format!("{fork_id}.familiar.json")),
            b"staged familiar",
        )
        .unwrap();
        std::fs::create_dir_all(storage.join("transcripts")).unwrap();
        std::fs::write(transcript_file(&storage, &fork_id), b"published transcript").unwrap();
        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        std::fs::write(familiar_file(&storage, &fork_id), b"published familiar").unwrap();

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!pending_fork_marker(&storage, &fork_id).exists());
        assert!(!transcript_file(&storage, &fork_id).exists());
        assert!(!familiar_file(&storage, &fork_id).exists());
        assert!(!storage.join(".fork-staging").exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn delete_pending_fork_uses_ordered_quarantine_cleanup() {
        let storage = test_storage("fork-pending-delete");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source = SessionPersistence::create(
            &storage_str,
            source_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        source
            .persist_new(&[Message::user("source message")])
            .await
            .unwrap();

        configure_session_faults(&storage, true, 1);
        fork_session(&storage_str, &source_id).await.unwrap_err();
        let fork_id = indexed_fork_id(&storage, &source_id);
        let marker = pending_fork_marker(&storage, &fork_id);

        clear_module_state_for_root(&storage).await;
        configure_session_faults(&storage, false, 1);
        let err = delete_session(&storage_str, &fork_id).await.unwrap_err();
        assert!(err
            .to_string()
            .contains("injected session index deletion failure"));
        assert!(transcript_file(&storage, &fork_id).exists());
        assert!(familiar_file(&storage, &fork_id).exists());
        assert!(marker.exists());

        clear_module_state_for_root(&storage).await;
        delete_session(&storage_str, &fork_id).await.unwrap();
        assert!(!index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .iter()
            .any(|row| row.id == fork_id));
        assert!(!transcript_file(&storage, &fork_id).exists());
        assert!(!familiar_file(&storage, &fork_id).exists());
        assert!(!marker.exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn malformed_source_familiar_never_publishes_a_fork() {
        let storage = test_storage("fork-rollback");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source_transcript = format!("{source_id}.jsonl");
        let persistence =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();
        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        std::fs::write(familiar_file(&storage, &source_id), b"not-json").unwrap();

        let err = fork_session(&storage_str, &source_id).await.unwrap_err();
        assert!(err.to_string().contains("cannot parse familiar metadata"));
        assert!(!err.to_string().contains("rolled back"));

        std::fs::remove_file(familiar_file(&storage, &source_id)).unwrap();
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, source_id);

        let mut transcripts = std::fs::read_dir(storage.join("transcripts"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();
        transcripts.sort();
        assert_eq!(transcripts, [std::ffi::OsString::from(source_transcript)]);

        let metadata = std::fs::read_dir(storage.join("metadata"))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(metadata.is_empty());
        assert!(!storage.join(".fork-staging").exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[test]
    fn post_create_metadata_write_failure_cleans_staged_file_and_directories() {
        let storage = test_storage("fork-partial-metadata");
        let fork_id = uuid::Uuid::new_v4().to_string();
        let mut stage = ForkStage::create(&storage, &fork_id).unwrap();
        let err = stage
            .stage_metadata_with(b"partial metadata", |path, _, context| {
                std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(path)
                    .map_err(|write_err| {
                        engine_err(&format!("cannot create {context}"), write_err)
                    })?;
                Err(engine_err(
                    &format!("cannot write {context}"),
                    std::io::Error::other("injected post-create write failure"),
                ))
            })
            .unwrap_err();
        assert!(err
            .to_string()
            .contains("injected post-create write failure"));

        let stage_directory = storage.join(".fork-staging").join(&fork_id);
        let staged_metadata = stage_directory.join(format!("{fork_id}.familiar.json"));
        assert!(staged_metadata.exists());

        let err = fork_stage_error("cannot stage fork familiar metadata", err, &mut stage);
        assert!(err
            .to_string()
            .contains("injected post-create write failure"));
        assert!(!staged_metadata.exists());
        assert!(!stage_directory.exists());
        assert!(!storage.join(".fork-staging").exists());
        assert!(pending_fork_ids(&storage).unwrap().is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[test]
    fn staging_directory_collision_cleans_marker_and_destination_artifacts() {
        let storage = test_storage("fork-staging-collision");
        let fork_id = uuid::Uuid::new_v4().to_string();
        let stage_directory = fork_staging_dir(&storage, &fork_id);
        std::fs::create_dir_all(&stage_directory).unwrap();
        std::fs::write(stage_directory.join("stale"), b"stale").unwrap();

        let err = match ForkStage::create(&storage, &fork_id) {
            Ok(_) => panic!("staging directory collision must fail"),
            Err(err) => err,
        };

        assert!(err
            .to_string()
            .contains("cannot create fork staging directory"));
        assert!(!storage.join(".fork-staging").exists());
        assert!(pending_fork_ids(&storage).unwrap().is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[test]
    fn staging_cleanup_sync_failure_is_combined_and_left_recoverable() {
        let storage = test_storage("fork-cleanup-sync-failure");
        let fork_id = uuid::Uuid::new_v4().to_string();
        let mut stage = ForkStage::create(&storage, &fork_id).unwrap();
        let stage_root = storage.join(".fork-staging");
        let write_err = stage
            .stage_metadata_with(b"partial metadata", |path, _, context| {
                std::fs::write(path, b"partial metadata")
                    .map_err(|err| engine_err(&format!("cannot write {context}"), err))?;
                Err(engine_err(
                    &format!("cannot write {context}"),
                    std::io::Error::other("injected staging write failure"),
                ))
            })
            .unwrap_err();
        fail_directory_sync(&stage_root, 1);

        let err = fork_stage_error("cannot stage fork familiar metadata", write_err, &mut stage);

        assert!(err.to_string().contains("injected staging write failure"));
        assert!(err.to_string().contains("cleanup also failed"));
        assert!(err.to_string().contains("injected directory sync failure"));
        assert!(pending_fork_marker(&storage, &fork_id).exists());

        let mut lifecycle = SessionLifecycle::default();
        recover_pending_forks_unlocked(&storage, &mut lifecycle).unwrap();
        assert!(!pending_fork_marker(&storage, &fork_id).exists());
        assert!(!stage_root.exists());

        DIRECTORY_SYNC_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&stage_root);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn cancelling_staged_fork_leaves_no_visible_or_artifact_session() {
        let storage = test_storage("fork-cancellation");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source = SessionPersistence::create(
            &storage_str,
            source_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        source
            .persist_new(&[
                Message::user("first source message"),
                Message::assistant("second source message"),
            ])
            .await
            .unwrap();

        let (staged_tx, staged_rx) = tokio::sync::oneshot::channel();
        let (_resume_tx, resume_rx) = tokio::sync::oneshot::channel();
        let fork_storage = storage_str.clone();
        let fork_source_id = source_id.clone();
        let fork_task = tokio::spawn(async move {
            fork_session_with_stage_pause(
                &fork_storage,
                &fork_source_id,
                ForkStagePause {
                    staged: staged_tx,
                    resume: resume_rx,
                },
            )
            .await
        });

        staged_rx.await.unwrap();
        let pending_ids = pending_fork_ids(&storage).unwrap();
        assert_eq!(pending_ids.len(), 1);
        assert!(fork_staging_dir(&storage, &pending_ids[0]).exists());
        fork_task.abort();
        let join_err = fork_task.await.unwrap_err();
        assert!(join_err.is_cancelled());

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, source_id);

        let transcripts = std::fs::read_dir(storage.join("transcripts"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();
        assert_eq!(
            transcripts,
            [std::ffi::OsString::from(format!("{source_id}.jsonl"))]
        );
        let metadata = std::fs::read_dir(storage.join("metadata"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();
        assert_eq!(
            metadata,
            [std::ffi::OsString::from(format!(
                "{source_id}.familiar.json"
            ))]
        );
        assert!(!storage.join(".fork-staging").exists());
        assert!(pending_fork_ids(&storage).unwrap().is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn resume_and_delete_serialize_through_the_lifecycle_lock() {
        let storage = test_storage("resume-delete-lock");
        let workspace = test_storage("resume-delete-workspace");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();
        save_familiar_metadata(&storage_str, &source_id, Some(&familiar())).unwrap();

        let write_guard = SESSION_LIFECYCLE_LOCK.write().await;
        let (resume_started_tx, resume_started_rx) = tokio::sync::oneshot::channel();
        let resume_storage = storage_str.clone();
        let resume_workspace = workspace.display().to_string();
        let resume_id = source_id.clone();
        let mut resume_task = tokio::spawn(async move {
            let _ = resume_started_tx.send(());
            crate::chat::resume_session(
                crate::PocketProvider::Anthropic,
                "key".to_string(),
                "model".to_string(),
                None,
                resume_workspace,
                crate::chat::ChatPermissionMode::Default,
                resume_storage,
                resume_id,
                false,
            )
            .await
        });
        resume_started_rx.await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut resume_task)
                .await
                .is_err(),
            "resume completed while lifecycle writes were excluded"
        );
        drop(write_guard);
        let resumed = resume_task.await.unwrap().unwrap();
        assert_eq!(resumed.session_id(), source_id);

        let read_guard = SESSION_LIFECYCLE_LOCK.read().await;
        let (delete_started_tx, delete_started_rx) = tokio::sync::oneshot::channel();
        let delete_storage = storage_str.clone();
        let delete_id = source_id.clone();
        let mut delete_task = tokio::spawn(async move {
            let _ = delete_started_tx.send(());
            delete_session(&delete_storage, &delete_id).await
        });
        delete_started_rx.await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut delete_task)
                .await
                .is_err(),
            "delete completed while a lifecycle reader was active"
        );
        drop(read_guard);
        delete_task.await.unwrap().unwrap();

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn fork_waits_for_lifecycle_readers_before_loading_the_source() {
        let storage = test_storage("fork-reader-lock");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        source
            .persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();
        let identity = familiar();
        save_familiar_metadata(&storage_str, &source_id, Some(&identity)).unwrap();

        let read_guard = SESSION_LIFECYCLE_LOCK.read().await;
        let (fork_started_tx, fork_started_rx) = tokio::sync::oneshot::channel();
        let fork_storage = storage_str.clone();
        let fork_source_id = source_id.clone();
        let mut fork_task = tokio::spawn(async move {
            let _ = fork_started_tx.send(());
            fork_session(&fork_storage, &fork_source_id).await
        });
        fork_started_rx.await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut fork_task)
                .await
                .is_err(),
            "fork loaded its source while a lifecycle reader was active"
        );
        drop(read_guard);

        let fork_id = fork_task.await.unwrap().unwrap();
        assert_eq!(
            load_familiar_metadata(&storage_str, &fork_id).unwrap(),
            Some(identity)
        );

        std::fs::remove_dir_all(storage).unwrap();
    }
}
