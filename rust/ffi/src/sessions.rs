//! On-device persistence for chat sessions.
//!
//! Layout under an app-provided absolute `storage_dir`:
//!
//! ```text
//! {storage_dir}/index.sqlite               — engine SqliteSessionStore (list/search index)
//! {storage_dir}/transcripts/{uuid}.jsonl   — engine-format JSONL transcript (full fidelity)
//! {storage_dir}/metadata/{uuid}.familiar.json — pinned familiar identity snapshot
//! ```
//!
//! Transcripts use the engine's `session_storage` wire format, so files are
//! readable by coven-code tooling and survive engine upgrades via its
//! forward-compatible parser. The SQLite index only serves the browser UI;
//! the JSONL file is the source of truth for restores.

use std::io::Write;
use std::path::{Path, PathBuf};

use claurst_core::session_storage::{
    load_transcript, make_assistant_entry, make_user_entry, messages_from_transcript,
    write_transcript_entry, TranscriptEntry,
};
use claurst_core::types::{Message, Role};
use claurst_core::SqliteSessionStore;

use crate::remote::FamiliarIdentity;
use crate::PocketError;

static SESSION_LIFECYCLE_LOCK: tokio::sync::RwLock<()> = tokio::sync::RwLock::const_new(());

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

fn storage_root(storage_dir: &str) -> Result<PathBuf, PocketError> {
    let root = PathBuf::from(storage_dir);
    if !root.is_absolute() {
        return Err(PocketError::Engine {
            message: format!("storage_dir must be absolute, got {storage_dir}"),
        });
    }
    std::fs::create_dir_all(&root).map_err(|e| engine_err("cannot create storage dir", e))?;
    Ok(root)
}

fn index_store(root: &Path) -> Result<SqliteSessionStore, PocketError> {
    SqliteSessionStore::open(&root.join("index.sqlite"))
        .map_err(|e| engine_err("cannot open session index", e))
}

fn indexed_session_model(root: &Path, session_id: &str) -> Result<String, PocketError> {
    index_store(root)?
        .list_sessions()
        .map_err(|e| engine_err("cannot list sessions", e))
        .map(|rows| {
            rows.into_iter()
                .find(|row| row.id == session_id)
                .map(|row| row.model)
                .unwrap_or_default()
        })
}

fn transcript_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("transcripts").join(format!("{session_id}.jsonl"))
}

fn familiar_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("metadata")
        .join(format!("{session_id}.familiar.json"))
}

fn remove_file_if_present(path: &Path, context: &str) -> Result<(), PocketError> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(engine_err(context, err)),
    }
}

/// Atomically save a pinned familiar snapshot, or remove it when absent.
pub(crate) fn save_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let destination = familiar_file(&root, session_id);
    let Some(familiar) = familiar else {
        return remove_file_if_present(&destination, "cannot delete familiar metadata");
    };

    let bytes = serde_json::to_vec(familiar)
        .map_err(|err| engine_err("cannot serialize familiar metadata", err))?;
    let metadata_dir = root.join("metadata");
    std::fs::create_dir_all(&metadata_dir)
        .map_err(|err| engine_err("cannot create metadata dir", err))?;
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
            .map_err(|err| engine_err("cannot install familiar metadata", err))
    })();

    if let Err(write_err) = write_result {
        return match remove_file_if_present(&temporary, "cannot clean temporary familiar metadata")
        {
            Ok(()) => Err(write_err),
            Err(cleanup_err) => Err(PocketError::Engine {
                message: format!("{write_err}; rollback also failed: {cleanup_err}"),
            }),
        };
    }
    Ok(())
}

/// Load a pinned familiar snapshot. Missing metadata is backward-compatible.
pub(crate) fn load_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
) -> Result<Option<FamiliarIdentity>, PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let bytes = match std::fs::read(familiar_file(&root, session_id)) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(engine_err("cannot read familiar metadata", err)),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|err| engine_err("cannot parse familiar metadata", err))
}

/// Copy optional familiar metadata between two explicit session IDs.
pub(crate) fn copy_familiar_metadata(
    storage_dir: &str,
    source_session_id: &str,
    destination_session_id: &str,
) -> Result<(), PocketError> {
    validate_session_id(destination_session_id)?;
    let familiar = load_familiar_metadata(storage_dir, source_session_id)?;
    save_familiar_metadata(storage_dir, destination_session_id, familiar.as_ref())
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
    root: PathBuf,
    session_id: String,
    model: String,
    state: tokio::sync::Mutex<PersistState>,
}

struct PersistState {
    persisted: usize,
    last_uuid: Option<String>,
}

impl SessionPersistence {
    pub(crate) fn create(
        storage_dir: &str,
        session_id: String,
        model: String,
    ) -> Result<Self, PocketError> {
        let root = storage_root(storage_dir)?;
        Ok(Self {
            root,
            session_id,
            model,
            state: tokio::sync::Mutex::new(PersistState {
                persisted: 0,
                last_uuid: None,
            }),
        })
    }

    pub(crate) fn resumed(
        storage_dir: &str,
        session_id: String,
        model: String,
        already_persisted: usize,
        last_uuid: Option<String>,
    ) -> Result<Self, PocketError> {
        let root = storage_root(storage_dir)?;
        Ok(Self {
            root,
            session_id,
            model,
            state: tokio::sync::Mutex::new(PersistState {
                persisted: already_persisted,
                last_uuid,
            }),
        })
    }

    /// Persist every message beyond the already-persisted prefix: append
    /// JSONL entries and mirror text into the SQLite index.
    pub(crate) async fn persist_new(&self, messages: &[Message]) -> Result<(), PocketError> {
        let mut state = self.state.lock().await;
        if messages.len() <= state.persisted {
            return Ok(());
        }

        let path = transcript_file(&self.root, &self.session_id);
        let store = index_store(&self.root)?;
        store
            .save_session(&self.session_id, Some(&derive_title(messages)), &self.model)
            .map_err(|e| engine_err("cannot index session", e))?;

        for message in &messages[state.persisted..] {
            let uuid = uuid::Uuid::new_v4().to_string();
            let entry = build_entry(
                message.clone(),
                &uuid,
                state.last_uuid.as_deref(),
                &self.session_id,
            );
            write_transcript_entry(&path, &entry)
                .await
                .map_err(|e| engine_err("cannot write transcript", e))?;
            store
                .save_message(
                    &self.session_id,
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

async fn load_session_messages_unlocked(
    storage_dir: &str,
    session_id: &str,
) -> Result<(Vec<Message>, Option<String>), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let path = transcript_file(&root, session_id);
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

/// Load the complete persisted state needed to resume under one read lock.
pub(crate) async fn load_session_snapshot(
    storage_dir: &str,
    session_id: &str,
) -> Result<(Vec<Message>, Option<String>, Option<FamiliarIdentity>), PocketError> {
    let _lifecycle_guard = SESSION_LIFECYCLE_LOCK.read().await;
    let (messages, last_uuid) = load_session_messages_unlocked(storage_dir, session_id).await?;
    let familiar = load_familiar_metadata(storage_dir, session_id)?;
    Ok((messages, last_uuid, familiar))
}

/// Newest-first summaries for the browser.
pub async fn list_sessions(storage_dir: &str) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let _lifecycle_guard = SESSION_LIFECYCLE_LOCK.read().await;
    list_sessions_unlocked(storage_dir)
}

fn list_sessions_unlocked(storage_dir: &str) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let root = storage_root(storage_dir)?;
    let store = index_store(&root)?;
    let rows = store
        .list_sessions()
        .map_err(|e| engine_err("cannot list sessions", e))?;
    rows.into_iter()
        .map(|s| {
            let familiar = load_familiar_metadata(storage_dir, &s.id)?;
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
    let _lifecycle_guard = SESSION_LIFECYCLE_LOCK.write().await;
    delete_session_unlocked(storage_dir, session_id)
}

fn delete_session_unlocked(storage_dir: &str, session_id: &str) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    index_store(&root)?
        .delete_session(session_id)
        .map_err(|e| engine_err("cannot delete session", e))?;
    remove_file_if_present(
        &transcript_file(&root, session_id),
        "cannot delete transcript",
    )?;
    save_familiar_metadata(storage_dir, session_id, None)
}

/// Copy a session's transcript under a fresh id at its current head.
/// Returns the new session id.
pub async fn fork_session(storage_dir: &str, session_id: &str) -> Result<String, PocketError> {
    let _lifecycle_guard = SESSION_LIFECYCLE_LOCK.write().await;
    fork_session_unlocked(storage_dir, session_id).await
}

async fn fork_session_unlocked(storage_dir: &str, session_id: &str) -> Result<String, PocketError> {
    let (messages, _) = load_session_messages_unlocked(storage_dir, session_id).await?;
    if messages.is_empty() {
        return Err(PocketError::Engine {
            message: format!("session {session_id} has no messages to fork"),
        });
    }
    let root = storage_root(storage_dir)?;

    // Model comes from the source's index row; the transcript doesn't carry it.
    let model = indexed_session_model(&root, session_id)?;

    let new_id = uuid::Uuid::new_v4().to_string();
    let path = transcript_file(&root, &new_id);
    let store = index_store(&root)?;
    store
        .save_session(&new_id, Some(&derive_title(&messages)), &model)
        .map_err(|e| engine_err("cannot index fork", e))?;

    let mut parent: Option<String> = None;
    for message in &messages {
        let uuid = uuid::Uuid::new_v4().to_string();
        let entry = build_entry(message.clone(), &uuid, parent.as_deref(), &new_id);
        write_transcript_entry(&path, &entry)
            .await
            .map_err(|e| engine_err("cannot write fork transcript", e))?;
        store
            .save_message(
                &new_id,
                &uuid,
                role_str(&message.role),
                &message.get_all_text(),
                None,
            )
            .map_err(|e| engine_err("cannot index fork message", e))?;
        parent = Some(uuid);
    }
    if let Err(copy_err) = copy_familiar_metadata(storage_dir, session_id, &new_id) {
        return match delete_session_unlocked(storage_dir, &new_id) {
            Ok(()) => Err(PocketError::Engine {
                message: format!("cannot copy familiar metadata: {copy_err}; fork rolled back"),
            }),
            Err(rollback_err) => Err(PocketError::Engine {
                message: format!(
                    "cannot copy familiar metadata: {copy_err}; fork rollback also failed: \
                     {rollback_err}"
                ),
            }),
        };
    }
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
    async fn fork_copies_familiar_and_delete_removes_its_sidecar() {
        let storage = test_storage("fork-metadata");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string())
                .unwrap();
        persistence
            .persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();
        let identity = familiar();
        save_familiar_metadata(&storage_str, &source_id, Some(&identity)).unwrap();

        let fork_id = fork_session(&storage_str, &source_id).await.unwrap();
        assert_eq!(
            load_familiar_metadata(&storage_str, &fork_id).unwrap(),
            Some(identity)
        );
        let fork_sidecar = storage
            .join("metadata")
            .join(format!("{fork_id}.familiar.json"));
        assert!(fork_sidecar.exists());

        delete_session(&storage_str, &fork_id).await.unwrap();
        assert!(!fork_sidecar.exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn malformed_source_familiar_rolls_back_the_visible_fork() {
        let storage = test_storage("fork-rollback");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source_transcript = format!("{source_id}.jsonl");
        let persistence =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string())
                .unwrap();
        persistence
            .persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();
        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        std::fs::write(familiar_file(&storage, &source_id), b"not-json").unwrap();

        let err = fork_session(&storage_str, &source_id).await.unwrap_err();
        assert!(err.to_string().contains("cannot parse familiar metadata"));
        assert!(err.to_string().contains("fork rolled back"));

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

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn resume_and_delete_serialize_through_the_lifecycle_lock() {
        let storage = test_storage("resume-delete-lock");
        let workspace = test_storage("resume-delete-workspace");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string())
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
    async fn list_and_delete_wait_until_fork_identity_is_published() {
        let storage = test_storage("fork-publication-lock");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string())
                .unwrap();
        source
            .persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();
        let identity = familiar();
        save_familiar_metadata(&storage_str, &source_id, Some(&identity)).unwrap();

        let write_guard = SESSION_LIFECYCLE_LOCK.write().await;
        let fork_id = uuid::Uuid::new_v4().to_string();
        let fork =
            SessionPersistence::create(&storage_str, fork_id.clone(), "model".to_string()).unwrap();
        fork.persist_new(&[Message::user("seeded source")])
            .await
            .unwrap();

        let (list_started_tx, list_started_rx) = tokio::sync::oneshot::channel();
        let list_storage = storage_str.clone();
        let mut list_task = tokio::spawn(async move {
            let _ = list_started_tx.send(());
            list_sessions(&list_storage).await
        });
        let (delete_started_tx, delete_started_rx) = tokio::sync::oneshot::channel();
        let delete_storage = storage_str.clone();
        let delete_id = source_id.clone();
        let mut delete_task = tokio::spawn(async move {
            let _ = delete_started_tx.send(());
            delete_session(&delete_storage, &delete_id).await
        });
        list_started_rx.await.unwrap();
        delete_started_rx.await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut list_task)
                .await
                .is_err(),
            "list observed the fork before its identity was published"
        );
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut delete_task)
                .await
                .is_err(),
            "delete interfered while the fork identity was unpublished"
        );

        save_familiar_metadata(&storage_str, &fork_id, Some(&identity)).unwrap();
        drop(write_guard);

        let listed = list_task.await.unwrap().unwrap();
        let fork_row = listed.iter().find(|row| row.session_id == fork_id).unwrap();
        assert_eq!(fork_row.familiar, Some(identity));
        delete_task.await.unwrap().unwrap();

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn fork_waits_for_lifecycle_readers_before_loading_the_source() {
        let storage = test_storage("fork-reader-lock");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string())
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
