//! On-device persistence for chat sessions.
//!
//! Layout under an app-provided absolute `storage_dir`:
//!
//! ```text
//! {storage_dir}/index.sqlite               — engine SqliteSessionStore (list/search index)
//! {storage_dir}/transcripts/{uuid}.jsonl   — engine-format JSONL transcript (full fidelity)
//! {storage_dir}/metadata/{uuid}.familiar.json — pinned familiar identity snapshot
//! {storage_dir}/.session-lifecycle/session-models/{uuid}.json — durable model metadata
//! {storage_dir}/.session-lifecycle/pending-forks/{uuid}.pending — incomplete fork quarantine
//! {storage_dir}/.session-lifecycle/pending-deletions/{uuid}.pending — incomplete deletion
//! {storage_dir}/.session-lifecycle/pending-index/{uuid}.json — one durable message-index intent
//! {storage_dir}/.session-lifecycle/index-baselines/{uuid}.json — legacy history reconciled marker
//! ```
//!
//! Transcripts use the engine's `session_storage` wire format, so files are
//! readable by coven-code tooling and survive engine upgrades via its
//! forward-compatible parser. The SQLite index only serves the browser UI;
//! the JSONL file is the source of truth for restores. Message appends publish
//! a versioned pending-index record before touching JSONL, sync the append,
//! publish the session row, replay `save_message` idempotently, and remove the
//! record last. Routine
//! recovery enumerates only those records; legacy transcripts reconcile once
//! on explicit resume or fork and then receive an index-baseline marker, so
//! stale legacy browser counts self-heal without making listing scan history.
//! If the SQLite cache is recreated, all baselines are invalidated without
//! reading transcripts; each session rebuilds lazily on its next resume/fork.
//!
//! Pending records are strict JSON objects with `version`, `session_id`,
//! `message_uuid`, `role`, `text`, `model`, and `title`. Baselines contain
//! `version` and `session_id`. Version 1 records reject unknown fields.
//! Atomic message-row/count commits remain the engine's responsibility
//! (coven-code PR #172); Pocket never reaches around `save_message`.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Weak};

use claurst_core::session_storage::{
    load_transcript, make_assistant_entry, make_user_entry, messages_from_transcript,
    write_transcript_entry, TranscriptEntry, MAX_TRANSCRIPT_BYTES,
};
use claurst_core::types::{Message, Role};
use claurst_core::SqliteSessionStore;

use crate::remote::FamiliarIdentity;
use crate::PocketError;

const INDEX_RECORD_VERSION: u32 = 1;
const MAX_BASELINE_RECORD_BYTES: u64 = 4 * 1024;
const MAX_SESSION_MODEL_RECORD_BYTES: u64 = 64 * 1024;
const MAX_INDEX_RECORD_ENVELOPE_BYTES: u64 = 4 * 1024;
const MAX_SESSION_TITLE_CHARS: usize = 60;
const MAX_LEGACY_INDEX_RECORD_BYTES: u64 = MAX_TRANSCRIPT_BYTES;
/// A pending record duplicates the indexable text from one transcript entry.
/// The transcript line itself is capped at 50 MiB; another 64 KiB is reserved
/// for model metadata, and 4 KiB covers the two UUIDs, role, JSON syntax, and
/// the derived title (at most [`MAX_SESSION_TITLE_CHARS`] Unicode scalar
/// values, including worst-case JSON escaping).
const MAX_INDEX_RECORD_BYTES: u64 =
    MAX_TRANSCRIPT_BYTES + MAX_SESSION_MODEL_RECORD_BYTES + MAX_INDEX_RECORD_ENVELOPE_BYTES;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct SessionKey {
    root: PathBuf,
    session_id: String,
}

enum SessionLifecycleState {
    Active {
        generation: uuid::Uuid,
        writer: Weak<SessionWriterLease>,
    },
    PendingFork,
    Tombstoned,
}

struct SessionWriterLease;

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
    fail_persist_before_first_intent_remaining: usize,
    fail_session_index_remaining: usize,
    fail_message_index_attempts: VecDeque<bool>,
    fail_transcript_append_remaining: usize,
    fail_transcript_after_write_remaining: usize,
}

#[cfg(test)]
static SESSION_TEST_FAULTS: LazyLock<std::sync::Mutex<HashMap<PathBuf, SessionTestFaults>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

#[cfg(test)]
#[derive(Clone, Debug, Eq, PartialEq)]
struct MessageIndexAttempt {
    root: PathBuf,
    session_id: String,
    uuid: String,
}

#[cfg(test)]
static MESSAGE_INDEX_ATTEMPTS: LazyLock<std::sync::Mutex<Vec<MessageIndexAttempt>>> =
    LazyLock::new(|| std::sync::Mutex::new(Vec::new()));

#[cfg(test)]
static DIRECTORY_SYNC_EVENTS: LazyLock<std::sync::Mutex<Vec<PathBuf>>> =
    LazyLock::new(|| std::sync::Mutex::new(Vec::new()));

#[cfg(test)]
static DIRECTORY_SYNC_FAILURES: LazyLock<std::sync::Mutex<HashMap<PathBuf, usize>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

#[cfg(test)]
static FILE_REMOVE_FAILURES: LazyLock<std::sync::Mutex<HashMap<PathBuf, usize>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

#[cfg(test)]
static FILE_CREATE_FAILURES: LazyLock<std::sync::Mutex<HashMap<PathBuf, usize>>> =
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

fn persistence_err(path: &Path, reason: impl std::fmt::Display) -> PocketError {
    PocketError::Engine {
        message: format!(
            "persistence error: unsafe storage path {}: {reason}",
            path.display()
        ),
    }
}

fn normalize_storage_root(root: &Path) -> Result<PathBuf, PocketError> {
    let mut normalized = PathBuf::new();
    for component in root.components() {
        match component {
            std::path::Component::ParentDir => {
                return Err(persistence_err(
                    root,
                    "configured storage root contains a parent component",
                ));
            }
            std::path::Component::CurDir => {}
            std::path::Component::Prefix(_)
            | std::path::Component::RootDir
            | std::path::Component::Normal(_) => normalized.push(component.as_os_str()),
        }
    }
    Ok(normalized)
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

#[derive(Clone, Debug)]
struct CheckedStorage {
    root: PathBuf,
}

impl CheckedStorage {
    fn open(storage_dir: &str) -> Result<Self, PocketError> {
        Self::open_path(PathBuf::from(storage_dir), storage_dir)
    }

    fn validate_existing_root_component(path: &Path) -> Result<(), PocketError> {
        let metadata = std::fs::symlink_metadata(path).map_err(|err| {
            persistence_err(
                path,
                format!("cannot inspect configured storage root component: {err}"),
            )
        })?;
        if metadata.file_type().is_symlink() {
            return Err(persistence_err(
                path,
                "configured storage root component is a symlink",
            ));
        }
        if !metadata.is_dir() {
            return Err(persistence_err(
                path,
                "configured storage root component is not a directory",
            ));
        }
        Ok(())
    }

    fn walk_root_components(root: &Path, create_missing: bool) -> Result<(), PocketError> {
        let mut current = PathBuf::new();
        let mut has_validated_parent = false;

        for component in root.components() {
            match component {
                std::path::Component::Prefix(_) => {
                    current.push(component.as_os_str());
                    if current.has_root() {
                        Self::validate_existing_root_component(&current)?;
                        has_validated_parent = true;
                    }
                }
                std::path::Component::RootDir => {
                    current.push(component.as_os_str());
                    Self::validate_existing_root_component(&current)?;
                    has_validated_parent = true;
                }
                std::path::Component::Normal(component) => {
                    if !has_validated_parent {
                        return Err(persistence_err(
                            &current,
                            "configured storage root component has no validated absolute parent",
                        ));
                    }
                    current.push(component);
                    match std::fs::symlink_metadata(&current) {
                        Ok(_) => Self::validate_existing_root_component(&current)?,
                        Err(err)
                            if create_missing && err.kind() == std::io::ErrorKind::NotFound =>
                        {
                            let parent = current.parent().ok_or_else(|| {
                                persistence_err(
                                    &current,
                                    "configured storage root component has no parent",
                                )
                            })?;
                            Self::validate_existing_root_component(parent)?;
                            match std::fs::create_dir(&current) {
                                Ok(()) => {}
                                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
                                Err(err) => {
                                    return Err(persistence_err(
                                        &current,
                                        format!(
                                            "cannot create configured storage root component: {err}"
                                        ),
                                    ));
                                }
                            }
                            Self::validate_existing_root_component(&current)?;
                        }
                        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                            return Err(persistence_err(
                                &current,
                                "configured storage root component is missing",
                            ));
                        }
                        Err(err) => {
                            return Err(persistence_err(
                                &current,
                                format!("cannot inspect configured storage root component: {err}"),
                            ));
                        }
                    }
                }
                std::path::Component::CurDir | std::path::Component::ParentDir => {
                    return Err(persistence_err(
                        root,
                        "configured storage root contains a non-normal component",
                    ));
                }
            }
        }
        Ok(())
    }

    fn open_path(root: PathBuf, display_path: &str) -> Result<Self, PocketError> {
        if !root.is_absolute() {
            return Err(PocketError::Engine {
                message: format!("storage_dir must be absolute, got {display_path}"),
            });
        }
        let root = normalize_storage_root(&root)?;
        Self::walk_root_components(&root, true)?;
        Self::walk_root_components(&root, false)?;
        let canonical_root = std::fs::canonicalize(&root)
            .map_err(|err| engine_err("cannot canonicalize storage dir", err))?;
        let storage = Self {
            root: canonical_root,
        };
        storage.validate_root()?;
        storage.validate_fixed_layout()?;
        Ok(storage)
    }

    #[cfg(test)]
    fn from_root(root: &Path) -> Result<Self, PocketError> {
        Self::open_path(root.to_path_buf(), &root.display().to_string())
    }

    fn root(&self) -> &Path {
        &self.root
    }

    fn validate_root(&self) -> Result<(), PocketError> {
        Self::walk_root_components(&self.root, false)?;
        let canonical = std::fs::canonicalize(&self.root)
            .map_err(|err| engine_err("cannot canonicalize storage root", err))?;
        if canonical != self.root {
            return Err(persistence_err(
                &self.root,
                format!(
                    "storage root resolves to unexpected path {}",
                    canonical.display()
                ),
            ));
        }
        Ok(())
    }

    fn child_path(&self, parent: &Path, component: &str) -> Result<PathBuf, PocketError> {
        let mut components = Path::new(component).components();
        if !matches!(components.next(), Some(std::path::Component::Normal(_)))
            || components.next().is_some()
        {
            return Err(persistence_err(
                parent,
                format!("invalid storage path component {component:?}"),
            ));
        }
        if parent != self.root && !parent.starts_with(&self.root) {
            return Err(persistence_err(
                parent,
                format!("parent is outside storage root {}", self.root.display()),
            ));
        }
        Ok(parent.join(component))
    }

    fn ensure_lexical_descendant(&self, path: &Path) -> Result<(), PocketError> {
        if path == self.root || !path.starts_with(&self.root) {
            return Err(persistence_err(
                path,
                format!(
                    "path is not a strict descendant of storage root {}",
                    self.root.display()
                ),
            ));
        }
        Ok(())
    }

    fn validate_canonical_descendant(&self, path: &Path) -> Result<(), PocketError> {
        let canonical = std::fs::canonicalize(path)
            .map_err(|err| engine_err("cannot canonicalize storage path", err))?;
        if canonical == self.root || !canonical.starts_with(&self.root) {
            return Err(persistence_err(
                path,
                format!(
                    "path resolves outside storage root {} to {}",
                    self.root.display(),
                    canonical.display()
                ),
            ));
        }
        Ok(())
    }

    fn validate_directory(&self, path: &Path, allow_missing: bool) -> Result<bool, PocketError> {
        self.validate_root()?;
        self.ensure_lexical_descendant(path)?;
        let relative = path.strip_prefix(&self.root).map_err(|_| {
            persistence_err(
                path,
                format!("path is outside storage root {}", self.root.display()),
            )
        })?;
        let mut current = self.root.clone();
        for component in relative.components() {
            let std::path::Component::Normal(component) = component else {
                return Err(persistence_err(
                    path,
                    "path contains a non-normal component",
                ));
            };
            current.push(component);
            match std::fs::symlink_metadata(&current) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    return Err(persistence_err(&current, "directory is a symlink"));
                }
                Ok(metadata) if !metadata.is_dir() => {
                    return Err(persistence_err(&current, "expected a directory"));
                }
                Ok(_) => self.validate_canonical_descendant(&current)?,
                Err(err) if allow_missing && err.kind() == std::io::ErrorKind::NotFound => {
                    return Ok(false);
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                    return Err(persistence_err(&current, "required directory is missing"));
                }
                Err(err) => return Err(engine_err("cannot inspect storage directory", err)),
            }
        }
        Ok(true)
    }

    fn validate_regular_file(&self, path: &Path, allow_missing: bool) -> Result<bool, PocketError> {
        self.validate_root()?;
        self.ensure_lexical_descendant(path)?;
        let parent = path.parent().ok_or_else(|| {
            persistence_err(path, "regular-file path has no containing directory")
        })?;
        if parent != self.root && !self.validate_directory(parent, true)? {
            return if allow_missing {
                Ok(false)
            } else {
                Err(persistence_err(
                    parent,
                    "required parent directory is missing",
                ))
            };
        }
        match std::fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                Err(persistence_err(path, "regular file is a symlink"))
            }
            Ok(metadata) if !metadata.is_file() => {
                Err(persistence_err(path, "expected a regular file"))
            }
            Ok(_) => {
                self.validate_canonical_descendant(path)?;
                Ok(true)
            }
            Err(err) if allow_missing && err.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                Err(persistence_err(path, "required regular file is missing"))
            }
            Err(err) => Err(engine_err("cannot inspect storage file", err)),
        }
    }

    fn metadata_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.root, "metadata")
    }

    fn transcripts_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.root, "transcripts")
    }

    fn lifecycle_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.root, ".session-lifecycle")
    }

    fn pending_forks_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.lifecycle_dir()?, "pending-forks")
    }

    fn pending_deletions_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.lifecycle_dir()?, "pending-deletions")
    }

    fn pending_index_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.lifecycle_dir()?, "pending-index")
    }

    fn session_models_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.lifecycle_dir()?, "session-models")
    }

    fn index_baselines_dir(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.lifecycle_dir()?, "index-baselines")
    }

    fn fork_staging_root(&self) -> Result<PathBuf, PocketError> {
        self.child_path(&self.root, ".fork-staging")
    }

    fn fork_staging_dir(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(&self.fork_staging_root()?, session_id)
    }

    fn transcript_file(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(&self.transcripts_dir()?, &format!("{session_id}.jsonl"))
    }

    fn familiar_file(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(
            &self.metadata_dir()?,
            &format!("{session_id}.familiar.json"),
        )
    }

    fn pending_fork_marker(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(&self.pending_forks_dir()?, &format!("{session_id}.pending"))
    }

    fn pending_deletion_marker(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(
            &self.pending_deletions_dir()?,
            &format!("{session_id}.pending"),
        )
    }

    fn pending_index_record(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(&self.pending_index_dir()?, &format!("{session_id}.json"))
    }

    fn pending_index_temporary(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(
            &self.pending_index_dir()?,
            &format!(".{session_id}.json.tmp"),
        )
    }

    fn session_model_record(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(&self.session_models_dir()?, &format!("{session_id}.json"))
    }

    fn session_model_temporary(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(
            &self.session_models_dir()?,
            &format!(".{session_id}.json.tmp"),
        )
    }

    fn index_baseline_record(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(&self.index_baselines_dir()?, &format!("{session_id}.json"))
    }

    fn index_baseline_temporary(&self, session_id: &str) -> Result<PathBuf, PocketError> {
        validate_session_id(session_id)?;
        self.child_path(
            &self.index_baselines_dir()?,
            &format!(".{session_id}.json.tmp"),
        )
    }

    fn index_file(&self, suffix: &str) -> Result<PathBuf, PocketError> {
        self.child_path(&self.root, &format!("index.sqlite{suffix}"))
    }

    fn validate_sqlite_files(&self) -> Result<(), PocketError> {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = self.index_file(suffix)?;
            self.validate_regular_file(&path, true)?;
        }
        Ok(())
    }

    fn validate_fixed_layout(&self) -> Result<(), PocketError> {
        for directory in [
            self.metadata_dir()?,
            self.transcripts_dir()?,
            self.lifecycle_dir()?,
            self.fork_staging_root()?,
        ] {
            self.validate_directory(&directory, true)?;
        }
        let lifecycle = self.lifecycle_dir()?;
        if self.validate_directory(&lifecycle, true)? {
            for pending in [
                self.pending_forks_dir()?,
                self.pending_deletions_dir()?,
                self.pending_index_dir()?,
                self.session_models_dir()?,
                self.index_baselines_dir()?,
            ] {
                self.validate_directory(&pending, true)?;
            }
        }
        self.validate_sqlite_files()
    }
}

fn checked_index_store(storage: &CheckedStorage) -> Result<SqliteSessionStore, PocketError> {
    storage.validate_sqlite_files()?;
    let index = storage.index_file("")?;
    let index_exists = storage.validate_regular_file(&index, true)?;
    if !index_exists {
        invalidate_index_baselines(storage)?;
    }
    SqliteSessionStore::open(&index).map_err(|err| engine_err("cannot open session index", err))
}

fn save_index_session(
    storage: &CheckedStorage,
    store: &SqliteSessionStore,
    session_id: &str,
    title: Option<&str>,
    model: &str,
    context: &str,
) -> Result<(), PocketError> {
    storage.validate_sqlite_files()?;
    #[cfg(test)]
    {
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(faults) = faults.get_mut(storage.root()) {
            if faults.fail_session_index_remaining > 0 {
                faults.fail_session_index_remaining -= 1;
                return Err(engine_err(
                    context,
                    std::io::Error::other("injected session index failure"),
                ));
            }
        }
    }
    store
        .save_session(session_id, title, model)
        .map_err(|err| engine_err(context, err))
}

#[cfg(test)]
fn fail_persist_before_first_intent_if_requested(
    storage: &CheckedStorage,
) -> Result<(), PocketError> {
    let mut faults = SESSION_TEST_FAULTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(faults) = faults.get_mut(storage.root()) {
        if faults.fail_persist_before_first_intent_remaining > 0 {
            faults.fail_persist_before_first_intent_remaining -= 1;
            return Err(engine_err(
                "cannot persist first message",
                std::io::Error::other("injected abort before first pending index intent"),
            ));
        }
    }
    Ok(())
}

fn save_index_message(
    storage: &CheckedStorage,
    store: &SqliteSessionStore,
    session_id: &str,
    uuid: &str,
    role: &str,
    text: &str,
    context: &str,
) -> Result<(), PocketError> {
    storage.validate_sqlite_files()?;
    #[cfg(test)]
    {
        MESSAGE_INDEX_ATTEMPTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(MessageIndexAttempt {
                root: storage.root().to_path_buf(),
                session_id: session_id.to_string(),
                uuid: uuid.to_string(),
            });
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(faults) = faults.get_mut(storage.root()) {
            if faults
                .fail_message_index_attempts
                .pop_front()
                .unwrap_or(false)
            {
                return Err(engine_err(
                    context,
                    std::io::Error::other("injected message index failure"),
                ));
            }
        }
    }
    store
        .save_message(session_id, uuid, role, text, None)
        .map_err(|err| engine_err(context, err))
}

fn rollback_transcript_append(
    storage: &CheckedStorage,
    path: &Path,
    directory: &Path,
    original_len: u64,
    existed: bool,
) -> Result<(), PocketError> {
    if existed {
        storage.validate_regular_file(path, false)?;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|err| engine_err("cannot reopen transcript for append rollback", err))?;
        file.set_len(original_len)
            .and_then(|()| file.sync_all())
            .map_err(|err| engine_err("cannot roll back partial transcript append", err))
    } else {
        remove_file_durably_if_present(
            storage,
            path,
            directory,
            "cannot roll back partial transcript append",
            "cannot sync partial transcript append rollback",
        )
    }
}

fn recover_complete_transcript_append(
    storage: &CheckedStorage,
    path: &Path,
    directory: &Path,
    original_len: u64,
    line: &[u8],
    existed: bool,
) -> Result<bool, PocketError> {
    storage.validate_regular_file(path, false)?;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|err| engine_err("cannot inspect uncertain transcript append", err))?;
    let expected_len = original_len.checked_add(line.len() as u64).ok_or_else(|| {
        engine_err(
            "cannot inspect uncertain transcript append",
            "size overflow",
        )
    })?;
    if file
        .metadata()
        .map_err(|err| engine_err("cannot inspect uncertain transcript append", err))?
        .len()
        != expected_len
    {
        return Ok(false);
    }
    file.seek(std::io::SeekFrom::Start(original_len))
        .map_err(|err| engine_err("cannot inspect uncertain transcript append", err))?;
    let mut actual = vec![0; line.len()];
    file.read_exact(&mut actual)
        .map_err(|err| engine_err("cannot inspect uncertain transcript append", err))?;
    if actual != line {
        return Ok(false);
    }
    file.sync_all()
        .map_err(|err| engine_err("cannot sync recovered transcript append", err))?;
    if !existed {
        sync_directory(
            storage,
            directory,
            "cannot sync recovered transcript file creation",
        )?;
    }
    Ok(true)
}

fn repair_incomplete_transcript_tail(
    storage: &CheckedStorage,
    path: &Path,
) -> Result<(), PocketError> {
    storage.validate_regular_file(path, false)?;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
    let len = file
        .metadata()
        .map_err(|err| engine_err("cannot inspect transcript tail", err))?
        .len();
    if len > MAX_TRANSCRIPT_BYTES {
        return Err(PocketError::Engine {
            message: format!(
                "cannot repair transcript tail: transcript file too large ({len} bytes, max \
                 {MAX_TRANSCRIPT_BYTES})"
            ),
        });
    }
    if len == 0 {
        return Ok(());
    }

    file.seek(std::io::SeekFrom::Start(len - 1))
        .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
    let mut last = [0_u8; 1];
    file.read_exact(&mut last)
        .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
    if last[0] == b'\n' {
        return Ok(());
    }

    const SCAN_CHUNK: u64 = 8 * 1024;
    let mut position = len;
    let mut truncate_to = 0;
    while position > 0 {
        let start = position.saturating_sub(SCAN_CHUNK);
        let chunk_len = usize::try_from(position - start)
            .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
        let mut chunk = vec![0_u8; chunk_len];
        file.seek(std::io::SeekFrom::Start(start))
            .and_then(|_| file.read_exact(&mut chunk))
            .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
        if let Some(index) = chunk.iter().rposition(|byte| *byte == b'\n') {
            truncate_to = start + index as u64 + 1;
            break;
        }
        position = start;
    }

    let tail_len = usize::try_from(len - truncate_to)
        .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
    let mut tail = vec![0_u8; tail_len];
    file.seek(std::io::SeekFrom::Start(truncate_to))
        .and_then(|_| file.read_exact(&mut tail))
        .map_err(|err| engine_err("cannot inspect transcript tail", err))?;
    if serde_json::from_slice::<serde_json::Value>(&tail).is_ok() {
        if len < MAX_TRANSCRIPT_BYTES {
            file.seek(std::io::SeekFrom::End(0))
                .and_then(|_| file.write_all(b"\n"))
                .and_then(|_| file.flush())
                .and_then(|_| file.sync_all())
                .map_err(|err| engine_err("cannot repair transcript final newline", err))?;
        }
        return Ok(());
    }

    file.set_len(truncate_to)
        .and_then(|()| file.sync_all())
        .map_err(|err| engine_err("cannot repair incomplete transcript tail", err))
}

struct TranscriptAppendError {
    error: PocketError,
    uncertain: bool,
}

impl TranscriptAppendError {
    fn uncertain(error: PocketError) -> Self {
        Self {
            error,
            uncertain: true,
        }
    }
}

impl From<PocketError> for TranscriptAppendError {
    fn from(error: PocketError) -> Self {
        Self {
            error,
            uncertain: false,
        }
    }
}

struct PreparedTranscriptAppend {
    line: Vec<u8>,
    existed: bool,
    original_len: u64,
}

fn inspect_transcript_append(
    storage: &CheckedStorage,
    path: &Path,
    line_len: u64,
) -> Result<(bool, u64), PocketError> {
    let (existed, original_len) = match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            storage.validate_regular_file(path, false)?;
            (true, metadata.len())
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => (false, 0),
        Err(err) => return Err(engine_err("cannot inspect transcript before append", err)),
    };
    if original_len >= MAX_TRANSCRIPT_BYTES
        || line_len > MAX_TRANSCRIPT_BYTES.saturating_sub(original_len)
    {
        return Err(PocketError::Engine {
            message: format!(
                "cannot write transcript: transcript size limit of {MAX_TRANSCRIPT_BYTES} bytes \
                 reached"
            ),
        });
    }
    Ok((existed, original_len))
}

fn prepare_transcript_append(
    storage: &CheckedStorage,
    path: &Path,
    entry: &TranscriptEntry,
) -> Result<PreparedTranscriptAppend, PocketError> {
    let mut line =
        serde_json::to_vec(entry).map_err(|err| engine_err("cannot serialize transcript", err))?;
    line.push(b'\n');
    let line_len =
        u64::try_from(line.len()).map_err(|err| engine_err("cannot serialize transcript", err))?;
    let (existed, original_len) = inspect_transcript_append(storage, path, line_len)?;
    Ok(PreparedTranscriptAppend {
        line,
        existed,
        original_len,
    })
}

fn append_transcript_entry(
    storage: &CheckedStorage,
    path: &Path,
    prepared: &PreparedTranscriptAppend,
) -> Result<(), TranscriptAppendError> {
    #[cfg(test)]
    {
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(faults) = faults.get_mut(storage.root()) {
            if faults.fail_transcript_append_remaining > 0 {
                faults.fail_transcript_append_remaining -= 1;
                return Err(engine_err(
                    "cannot write transcript",
                    std::io::Error::other("injected transcript append failure"),
                )
                .into());
            }
        }
    }

    let line_len = u64::try_from(prepared.line.len())
        .map_err(|err| engine_err("cannot write transcript", err))?;
    let (existed, original_len) = inspect_transcript_append(storage, path, line_len)?;
    if existed != prepared.existed || original_len != prepared.original_len {
        return Err(PocketError::Engine {
            message: "cannot write transcript: transcript changed after append preflight"
                .to_string(),
        }
        .into());
    }
    let directory = path
        .parent()
        .ok_or_else(|| persistence_err(path, "transcript path has no containing directory"))?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|err| engine_err("cannot write transcript", err))?;

    let mut write_result = file.write_all(&prepared.line);
    #[cfg(test)]
    {
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if write_result.is_ok() {
            if let Some(faults) = faults.get_mut(storage.root()) {
                if faults.fail_transcript_after_write_remaining > 0 {
                    faults.fail_transcript_after_write_remaining -= 1;
                    write_result = Err(std::io::Error::other(
                        "injected post-write transcript failure",
                    ));
                }
            }
        }
    }
    if write_result.is_ok() {
        write_result = file.flush();
    }
    if write_result.is_ok() {
        write_result = file.sync_all();
    }
    if let Err(write_err) = write_result {
        drop(file);
        match rollback_transcript_append(storage, path, directory, original_len, existed) {
            Ok(()) => return Err(engine_err("cannot write transcript", write_err).into()),
            Err(first_rollback_err) => {
                if recover_complete_transcript_append(
                    storage,
                    path,
                    directory,
                    original_len,
                    &prepared.line,
                    existed,
                )
                .unwrap_or(false)
                {
                    return Ok(());
                }
                return match rollback_transcript_append(
                    storage,
                    path,
                    directory,
                    original_len,
                    existed,
                ) {
                    Ok(()) => Err(engine_err("cannot write transcript", write_err).into()),
                    Err(second_rollback_err) => {
                        Err(TranscriptAppendError::uncertain(PocketError::Engine {
                            message: format!(
                                "cannot write transcript: {write_err}; append rollback failed twice: \
                                 {first_rollback_err}; {second_rollback_err}"
                            ),
                        }))
                    }
                };
            }
        }
    }
    if !existed {
        drop(file);
        if let Err(sync_err) =
            sync_directory(storage, directory, "cannot sync transcript file creation")
        {
            return match remove_file_durably_if_present(
                storage,
                path,
                directory,
                "cannot roll back transcript file creation",
                "cannot sync transcript file creation rollback",
            ) {
                Ok(()) => Err(sync_err.into()),
                Err(rollback_err) => Err(TranscriptAppendError::uncertain(PocketError::Engine {
                    message: format!("{sync_err}; rollback also failed: {rollback_err}"),
                })),
            };
        }
    }
    Ok(())
}

#[cfg(test)]
fn index_store(root: &Path) -> Result<SqliteSessionStore, PocketError> {
    checked_index_store(&CheckedStorage::from_root(root)?)
}

fn delete_index_session(
    storage: &CheckedStorage,
    session_id: &str,
    context: &str,
) -> Result<(), PocketError> {
    storage.validate_sqlite_files()?;
    #[cfg(test)]
    {
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(faults) = faults.get_mut(storage.root()) {
            if faults.fail_index_delete_remaining > 0 {
                faults.fail_index_delete_remaining -= 1;
                return Err(engine_err(
                    context,
                    std::io::Error::other("injected session index deletion failure"),
                ));
            }
        }
    }

    checked_index_store(storage).and_then(|store| {
        store
            .delete_session(session_id)
            .map_err(|err| engine_err(context, err))
    })
}

#[cfg(test)]
fn fail_fork_publication_after_row_if_requested(
    storage: &CheckedStorage,
) -> Result<(), PocketError> {
    let mut faults = SESSION_TEST_FAULTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(faults) = faults.get_mut(storage.root()) {
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

fn indexed_session_model(
    storage: &CheckedStorage,
    store: &SqliteSessionStore,
    session_id: &str,
) -> Result<Option<String>, PocketError> {
    storage.validate_sqlite_files()?;
    let rows = store
        .list_sessions()
        .map_err(|err| engine_err("cannot list sessions", err))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    Ok(rows
        .into_iter()
        .find(|row| row.id == session_id)
        .map(|row| row.model))
}

#[cfg(test)]
fn transcript_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("transcripts").join(format!("{session_id}.jsonl"))
}

#[cfg(test)]
fn familiar_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("metadata")
        .join(format!("{session_id}.familiar.json"))
}

#[cfg(test)]
fn pending_forks_dir(root: &Path) -> PathBuf {
    root.join(".session-lifecycle").join("pending-forks")
}

#[cfg(test)]
fn pending_fork_marker(root: &Path, session_id: &str) -> PathBuf {
    pending_forks_dir(root).join(format!("{session_id}.pending"))
}

#[cfg(test)]
fn pending_deletions_dir(root: &Path) -> PathBuf {
    root.join(".session-lifecycle").join("pending-deletions")
}

#[cfg(test)]
fn pending_deletion_marker(root: &Path, session_id: &str) -> PathBuf {
    pending_deletions_dir(root).join(format!("{session_id}.pending"))
}

#[cfg(test)]
fn fork_staging_dir(root: &Path, session_id: &str) -> PathBuf {
    root.join(".fork-staging").join(session_id)
}

/*
 * Persistence remains path-based because std does not expose portable
 * descriptor-relative filesystem operations. Every operation below rechecks
 * symlink/type/containment immediately before use, but a hostile concurrent
 * filesystem actor can still race those checks.
 */

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
        Some(SessionLifecycleState::Active {
            generation: active, ..
        }) if *active == generation => Ok(()),
        Some(SessionLifecycleState::Tombstoned) => Err(PocketError::Engine {
            message: format!("session {} was deleted", key.session_id),
        }),
        Some(SessionLifecycleState::Active { .. })
        | Some(SessionLifecycleState::PendingFork)
        | None => Err(PocketError::Engine {
            message: format!(
                "session persistence handle for {} was invalidated",
                key.session_id
            ),
        }),
    }
}

fn sync_directory(storage: &CheckedStorage, path: &Path, context: &str) -> Result<(), PocketError> {
    if path == storage.root() {
        storage.validate_root()?;
    } else {
        storage.validate_directory(path, false)?;
    }
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

fn sync_directory_if_present(
    storage: &CheckedStorage,
    path: &Path,
    context: &str,
) -> Result<(), PocketError> {
    if path == storage.root() {
        return sync_directory(storage, path, context);
    }
    if storage.validate_directory(path, true)? {
        sync_directory(storage, path, context)
    } else {
        Ok(())
    }
}

fn ensure_durable_directory(
    storage: &CheckedStorage,
    parent: &Path,
    directory: &Path,
    create_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    if parent == storage.root() {
        storage.validate_root()?;
    } else {
        storage.validate_directory(parent, false)?;
    }
    if storage.validate_directory(directory, true)? {
        return sync_directory(storage, parent, sync_context);
    }
    match std::fs::create_dir(directory) {
        Ok(()) => {
            storage.validate_directory(directory, false)?;
            sync_directory(storage, parent, sync_context)
        }
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            storage.validate_directory(directory, false)?;
            sync_directory(storage, parent, sync_context)
        }
        Err(err) => Err(engine_err(create_context, err)),
    }
}

fn remove_file(path: &Path) -> std::io::Result<()> {
    #[cfg(test)]
    {
        let mut failures = FILE_REMOVE_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(remaining) = failures.get_mut(path) {
            if *remaining > 0 {
                *remaining -= 1;
                return Err(std::io::Error::other("injected file removal failure"));
            }
        }
    }
    std::fs::remove_file(path)
}

fn remove_file_durably_if_present(
    storage: &CheckedStorage,
    path: &Path,
    directory: &Path,
    remove_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    if !storage.validate_directory(directory, true)? {
        return Ok(());
    }
    if !storage.validate_regular_file(path, true)? {
        return sync_directory(storage, directory, sync_context);
    }
    storage.validate_regular_file(path, false)?;
    match remove_file(path) {
        Ok(()) => sync_directory(storage, directory, sync_context),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            sync_directory_if_present(storage, directory, sync_context)
        }
        Err(err) => Err(engine_err(remove_context, err)),
    }
}

fn remove_dir_durably_if_present(
    storage: &CheckedStorage,
    path: &Path,
    parent: &Path,
    remove_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    if !storage.validate_directory(path, true)? {
        return sync_directory_if_present(storage, parent, sync_context);
    }
    storage.validate_directory(path, false)?;
    match std::fs::remove_dir(path) {
        Ok(()) => sync_directory(storage, parent, sync_context),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            sync_directory_if_present(storage, parent, sync_context)
        }
        Err(err) => Err(engine_err(remove_context, err)),
    }
}

#[derive(Default)]
struct RemovalPlan {
    files: Vec<PathBuf>,
    directories: Vec<PathBuf>,
}

fn collect_removal_plan(
    storage: &CheckedStorage,
    directory: &Path,
    plan: &mut RemovalPlan,
) -> Result<(), PocketError> {
    storage.validate_directory(directory, false)?;
    let entries = std::fs::read_dir(directory)
        .map_err(|err| engine_err("cannot inspect storage cleanup directory", err))?;
    for entry in entries {
        let entry = entry.map_err(|err| engine_err("cannot inspect storage cleanup entry", err))?;
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|err| engine_err("cannot inspect storage cleanup path", err))?;
        if metadata.file_type().is_symlink() {
            return Err(persistence_err(&path, "cleanup entry is a symlink"));
        }
        if metadata.is_dir() {
            storage.validate_directory(&path, false)?;
            collect_removal_plan(storage, &path, plan)?;
        } else if metadata.is_file() {
            storage.validate_regular_file(&path, false)?;
            plan.files.push(path);
        } else {
            return Err(persistence_err(
                &path,
                "cleanup entry is not a regular file or directory",
            ));
        }
    }
    plan.directories.push(directory.to_path_buf());
    Ok(())
}

fn preflight_removal_tree(
    storage: &CheckedStorage,
    directory: &Path,
) -> Result<Option<RemovalPlan>, PocketError> {
    if !storage.validate_directory(directory, true)? {
        return Ok(None);
    }
    let mut plan = RemovalPlan::default();
    collect_removal_plan(storage, directory, &mut plan)?;
    Ok(Some(plan))
}

fn remove_tree_durably_if_present(
    storage: &CheckedStorage,
    path: &Path,
    parent: &Path,
    remove_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    let Some(plan) = preflight_removal_tree(storage, path)? else {
        return sync_directory_if_present(storage, parent, sync_context);
    };
    for file in plan.files {
        storage.validate_regular_file(&file, false)?;
        remove_file(&file).map_err(|err| engine_err(remove_context, err))?;
    }
    for directory in plan.directories {
        storage.validate_directory(&directory, false)?;
        std::fs::remove_dir(&directory).map_err(|err| engine_err(remove_context, err))?;
    }
    sync_directory(storage, parent, sync_context)
}

fn remove_empty_fork_staging_root(storage: &CheckedStorage) -> Result<(), PocketError> {
    let stage_root = storage.fork_staging_root()?;
    if !storage.validate_directory(&stage_root, true)? {
        return sync_directory(
            storage,
            storage.root(),
            "cannot sync absent fork staging root",
        );
    }
    storage.validate_directory(&stage_root, false)?;
    match std::fs::remove_dir(&stage_root) {
        Ok(()) => sync_directory(
            storage,
            storage.root(),
            "cannot sync fork staging root removal",
        ),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => sync_directory(
            storage,
            storage.root(),
            "cannot sync absent fork staging root",
        ),
        Err(err) if err.kind() == std::io::ErrorKind::DirectoryNotEmpty => Ok(()),
        Err(err) => Err(engine_err("cannot remove fork staging root", err)),
    }
}

fn remove_fork_staging_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let stage_root = storage.fork_staging_root()?;
    let stage_directory = storage.fork_staging_dir(session_id)?;
    remove_tree_durably_if_present(
        storage,
        &stage_directory,
        &stage_root,
        "cannot delete fork staging artifacts",
        "cannot sync fork staging artifact removal",
    )?;
    remove_empty_fork_staging_root(storage)
}

fn invalidate_index_baselines(storage: &CheckedStorage) -> Result<(), PocketError> {
    let lifecycle = storage.lifecycle_dir()?;
    let baselines = storage.index_baselines_dir()?;
    remove_tree_durably_if_present(
        storage,
        &baselines,
        &lifecycle,
        "cannot invalidate index baselines for recreated index",
        "cannot sync invalidated index baselines",
    )
}

fn write_new_file(
    storage: &CheckedStorage,
    path: &Path,
    bytes: &[u8],
    context: &str,
) -> Result<(), PocketError> {
    storage.validate_regular_file(path, true)?;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|err| engine_err(&format!("cannot create {context}"), err))?;
    storage.validate_regular_file(path, false)?;
    file.write_all(bytes)
        .map_err(|err| engine_err(&format!("cannot write {context}"), err))?;
    file.sync_all()
        .map_err(|err| engine_err(&format!("cannot sync {context}"), err))
}

fn rename_checked_file(
    storage: &CheckedStorage,
    source: &Path,
    destination: &Path,
    context: &str,
) -> Result<(), PocketError> {
    storage
        .validate_regular_file(source, false)
        .map_err(|err| engine_err(context, err))?;
    storage
        .validate_regular_file(destination, true)
        .map_err(|err| engine_err(context, err))?;
    std::fs::rename(source, destination).map_err(|err| engine_err(context, err))?;
    storage
        .validate_regular_file(destination, false)
        .map(|_| ())
        .map_err(|err| engine_err(context, err))
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct PendingIndexRecord {
    version: u32,
    session_id: String,
    message_uuid: String,
    role: String,
    text: String,
    model: String,
    title: String,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct IndexBaselineRecord {
    version: u32,
    session_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct SessionModelRecord {
    version: u32,
    session_id: String,
    model: String,
}

fn validate_pending_index_record(
    record: &PendingIndexRecord,
    path: &Path,
    expected_session_id: &str,
) -> Result<(), PocketError> {
    if record.version != INDEX_RECORD_VERSION {
        return Err(persistence_err(
            path,
            format!(
                "unsupported pending index record version {}",
                record.version
            ),
        ));
    }
    validate_session_id(&record.session_id).map_err(|err| {
        persistence_err(path, format!("invalid pending index session UUID: {err}"))
    })?;
    if record.session_id != expected_session_id {
        return Err(persistence_err(
            path,
            format!(
                "pending index record session {} does not match file session {expected_session_id}",
                record.session_id
            ),
        ));
    }
    uuid::Uuid::parse_str(&record.message_uuid).map_err(|_| {
        persistence_err(
            path,
            format!("invalid pending index message UUID {}", record.message_uuid),
        )
    })?;
    if !matches!(record.role.as_str(), "user" | "assistant") {
        return Err(persistence_err(
            path,
            format!("invalid pending index role {:?}", record.role),
        ));
    }
    Ok(())
}

fn validate_index_baseline_record(
    record: &IndexBaselineRecord,
    path: &Path,
    expected_session_id: &str,
) -> Result<(), PocketError> {
    if record.version != INDEX_RECORD_VERSION {
        return Err(persistence_err(
            path,
            format!(
                "unsupported index baseline record version {}",
                record.version
            ),
        ));
    }
    validate_session_id(&record.session_id)
        .map_err(|err| persistence_err(path, format!("invalid baseline session UUID: {err}")))?;
    if record.session_id != expected_session_id {
        return Err(persistence_err(
            path,
            format!(
                "index baseline record session {} does not match file session \
                 {expected_session_id}",
                record.session_id
            ),
        ));
    }
    Ok(())
}

fn validate_session_model_record(
    record: &SessionModelRecord,
    path: &Path,
    expected_session_id: &str,
) -> Result<(), PocketError> {
    if record.version != INDEX_RECORD_VERSION {
        return Err(persistence_err(
            path,
            format!(
                "unsupported session model record version {}",
                record.version
            ),
        ));
    }
    validate_session_id(&record.session_id)
        .map_err(|err| persistence_err(path, format!("invalid model session UUID: {err}")))?;
    if record.session_id != expected_session_id {
        return Err(persistence_err(
            path,
            format!(
                "session model record session {} does not match file session \
                 {expected_session_id}",
                record.session_id
            ),
        ));
    }
    Ok(())
}

fn read_json_record<T>(
    storage: &CheckedStorage,
    path: &Path,
    max_bytes: u64,
    context: &str,
) -> Result<T, PocketError>
where
    T: for<'de> serde::Deserialize<'de>,
{
    storage.validate_regular_file(path, false)?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|err| engine_err(context, err))?;
    let len = file
        .metadata()
        .map_err(|err| engine_err(context, err))?
        .len();
    if len > max_bytes {
        return Err(persistence_err(
            path,
            format!("record is too large ({len} bytes, max {max_bytes})"),
        ));
    }
    let capacity = usize::try_from(len)
        .map_err(|err| engine_err(context, format!("record size does not fit memory: {err}")))?;
    let mut bytes = Vec::with_capacity(capacity);
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|err| engine_err(context, err))?;
    if bytes.len() as u64 > max_bytes {
        return Err(persistence_err(
            path,
            format!("record grew beyond the size limit while reading (max {max_bytes} bytes)"),
        ));
    }
    serde_json::from_slice(&bytes).map_err(|err| engine_err(context, err))
}

fn sync_record_file(
    storage: &CheckedStorage,
    path: &Path,
    context: &str,
) -> Result<(), PocketError> {
    storage.validate_regular_file(path, false)?;
    std::fs::OpenOptions::new()
        .read(true)
        .open(path)
        .and_then(|file| file.sync_all())
        .map_err(|err| engine_err(context, err))
}

fn ensure_lifecycle_record_directory(
    storage: &CheckedStorage,
    directory: &Path,
    create_context: &str,
    sync_context: &str,
) -> Result<(), PocketError> {
    let lifecycle = storage.lifecycle_dir()?;
    ensure_durable_directory(
        storage,
        storage.root(),
        &lifecycle,
        "cannot create session lifecycle directory",
        "cannot sync session lifecycle directory creation",
    )?;
    ensure_durable_directory(storage, &lifecycle, directory, create_context, sync_context)
}

fn write_json_record_atomically(
    storage: &CheckedStorage,
    directory: &Path,
    temporary: &Path,
    destination: &Path,
    bytes: &[u8],
    context: &str,
    directory_sync_context: &str,
) -> Result<(), PocketError> {
    storage.validate_directory(directory, false)?;
    storage.validate_regular_file(destination, true)?;
    storage.validate_regular_file(temporary, true)?;
    remove_file_durably_if_present(
        storage,
        temporary,
        directory,
        &format!("cannot remove stale temporary {context}"),
        &format!("cannot sync stale temporary {context} removal"),
    )?;

    let mut installed = false;
    let result = (|| -> Result<(), PocketError> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(temporary)
            .map_err(|err| engine_err(&format!("cannot create temporary {context}"), err))?;
        storage.validate_regular_file(temporary, false)?;
        file.write_all(bytes)
            .map_err(|err| engine_err(&format!("cannot write temporary {context}"), err))?;
        file.sync_all()
            .map_err(|err| engine_err(&format!("cannot sync temporary {context}"), err))?;
        rename_checked_file(
            storage,
            temporary,
            destination,
            &format!("cannot install {context}"),
        )?;
        installed = true;
        sync_directory(storage, directory, directory_sync_context)
    })();

    if let Err(write_err) = result {
        if installed {
            return Err(write_err);
        }
        return match remove_file_durably_if_present(
            storage,
            temporary,
            directory,
            &format!("cannot clean temporary {context}"),
            &format!("cannot sync temporary {context} cleanup"),
        ) {
            Ok(()) => Err(write_err),
            Err(cleanup_err) => Err(PocketError::Engine {
                message: format!("{write_err}; cleanup also failed: {cleanup_err}"),
            }),
        };
    }
    Ok(())
}

fn read_pending_index_record(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<Option<PendingIndexRecord>, PocketError> {
    let path = storage.pending_index_record(session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Ok(None);
    }
    let record = read_json_record(
        storage,
        &path,
        MAX_INDEX_RECORD_BYTES,
        "cannot parse pending index record",
    )?;
    validate_pending_index_record(&record, &path, session_id)?;
    Ok(Some(record))
}

fn write_pending_index_record(
    storage: &CheckedStorage,
    record: &PendingIndexRecord,
) -> Result<(), PocketError> {
    validate_session_id(&record.session_id)?;
    let destination = storage.pending_index_record(&record.session_id)?;
    validate_pending_index_record(record, &destination, &record.session_id)?;
    let bytes = serde_json::to_vec(record)
        .map_err(|err| engine_err("cannot serialize pending index record", err))?;
    if bytes.len() as u64 > MAX_INDEX_RECORD_BYTES {
        return Err(PocketError::Engine {
            message: format!(
                "cannot write pending index record: pending index record size limit of \
                 {MAX_INDEX_RECORD_BYTES} bytes exceeded ({} bytes)",
                bytes.len()
            ),
        });
    }
    let directory = storage.pending_index_dir()?;
    ensure_lifecycle_record_directory(
        storage,
        &directory,
        "cannot create pending index directory",
        "cannot sync pending index directory creation",
    )?;
    if let Some(existing) = read_pending_index_record(storage, &record.session_id)? {
        if existing != *record {
            return Err(PocketError::Engine {
                message: format!(
                    "pending index record mismatch for session {}",
                    record.session_id
                ),
            });
        }
        sync_record_file(
            storage,
            &destination,
            "cannot sync existing pending index record",
        )?;
        return sync_directory(
            storage,
            &directory,
            "cannot sync existing pending index directory",
        );
    }
    let temporary = storage.pending_index_temporary(&record.session_id)?;
    write_json_record_atomically(
        storage,
        &directory,
        &temporary,
        &destination,
        &bytes,
        "pending index record",
        "cannot sync pending index record installation",
    )
}

fn remove_pending_index_record(
    storage: &CheckedStorage,
    record: &PendingIndexRecord,
    missing_ok: bool,
) -> Result<(), PocketError> {
    let directory = storage.pending_index_dir()?;
    let path = storage.pending_index_record(&record.session_id)?;
    let Some(existing) = read_pending_index_record(storage, &record.session_id)? else {
        if missing_ok {
            return sync_directory_if_present(
                storage,
                &directory,
                "cannot sync absent pending index marker removal",
            );
        }
        return Err(engine_err(
            "cannot remove pending index marker",
            std::io::Error::from(std::io::ErrorKind::NotFound),
        ));
    };
    if existing != *record {
        return Err(PocketError::Engine {
            message: format!(
                "pending index record mismatch for session {}",
                record.session_id
            ),
        });
    }
    let remove_result = remove_file_durably_if_present(
        storage,
        &path,
        &directory,
        "cannot remove pending index marker",
        "cannot sync pending index marker removal",
    );
    if let Err(remove_err) = remove_result {
        if storage.validate_regular_file(&path, true)? {
            return Err(remove_err);
        }
        return match write_pending_index_record(storage, record) {
            Ok(()) => Err(remove_err),
            Err(restore_err) => Err(PocketError::Engine {
                message: format!(
                    "{remove_err}; cannot restore pending index marker: {restore_err}"
                ),
            }),
        };
    }
    Ok(())
}

fn remove_pending_index_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let directory = storage.pending_index_dir()?;
    let destination = storage.pending_index_record(session_id)?;
    remove_file_durably_if_present(
        storage,
        &destination,
        &directory,
        "cannot remove pending index record",
        "cannot sync pending index record removal",
    )?;
    let temporary = storage.pending_index_temporary(session_id)?;
    remove_file_durably_if_present(
        storage,
        &temporary,
        &directory,
        "cannot remove temporary pending index record",
        "cannot sync temporary pending index record removal",
    )
}

fn read_index_baseline(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<Option<IndexBaselineRecord>, PocketError> {
    let path = storage.index_baseline_record(session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Ok(None);
    }
    let record = read_json_record(
        storage,
        &path,
        MAX_BASELINE_RECORD_BYTES,
        "cannot parse index baseline record",
    )?;
    validate_index_baseline_record(&record, &path, session_id)?;
    Ok(Some(record))
}

fn read_session_model_record(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<Option<SessionModelRecord>, PocketError> {
    let path = storage.session_model_record(session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Ok(None);
    }
    let record = read_json_record(
        storage,
        &path,
        MAX_SESSION_MODEL_RECORD_BYTES,
        "cannot parse session model record",
    )?;
    validate_session_model_record(&record, &path, session_id)?;
    Ok(Some(record))
}

fn write_session_model_record(
    storage: &CheckedStorage,
    session_id: &str,
    model: &str,
) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let directory = storage.session_models_dir()?;
    ensure_lifecycle_record_directory(
        storage,
        &directory,
        "cannot create session models directory",
        "cannot sync session models directory creation",
    )?;
    let destination = storage.session_model_record(session_id)?;
    let record = SessionModelRecord {
        version: INDEX_RECORD_VERSION,
        session_id: session_id.to_string(),
        model: model.to_string(),
    };
    if let Some(existing) = read_session_model_record(storage, session_id)? {
        if existing == record {
            sync_record_file(
                storage,
                &destination,
                "cannot sync existing session model record",
            )?;
            return sync_directory(
                storage,
                &directory,
                "cannot sync existing session models directory",
            );
        }
    }
    validate_session_model_record(&record, &destination, session_id)?;
    let bytes = serde_json::to_vec(&record)
        .map_err(|err| engine_err("cannot serialize session model record", err))?;
    let temporary = storage.session_model_temporary(session_id)?;
    write_json_record_atomically(
        storage,
        &directory,
        &temporary,
        &destination,
        &bytes,
        "session model record",
        "cannot sync session model record installation",
    )
}

fn remove_session_model_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let directory = storage.session_models_dir()?;
    let destination = storage.session_model_record(session_id)?;
    remove_file_durably_if_present(
        storage,
        &destination,
        &directory,
        "cannot remove session model record",
        "cannot sync session model record removal",
    )?;
    let temporary = storage.session_model_temporary(session_id)?;
    remove_file_durably_if_present(
        storage,
        &temporary,
        &directory,
        "cannot remove temporary session model record",
        "cannot sync temporary session model record removal",
    )
}

fn write_index_baseline(storage: &CheckedStorage, session_id: &str) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    drop(checked_index_store(storage)?);
    let directory = storage.index_baselines_dir()?;
    ensure_lifecycle_record_directory(
        storage,
        &directory,
        "cannot create index baselines directory",
        "cannot sync index baselines directory creation",
    )?;
    let destination = storage.index_baseline_record(session_id)?;
    let record = IndexBaselineRecord {
        version: INDEX_RECORD_VERSION,
        session_id: session_id.to_string(),
    };
    if let Some(existing) = read_index_baseline(storage, session_id)? {
        if existing != record {
            return Err(PocketError::Engine {
                message: format!("index baseline record mismatch for session {session_id}"),
            });
        }
        sync_record_file(
            storage,
            &destination,
            "cannot sync existing index baseline record",
        )?;
        return sync_directory(
            storage,
            &directory,
            "cannot sync existing index baseline directory",
        );
    }
    let bytes = serde_json::to_vec(&record)
        .map_err(|err| engine_err("cannot serialize index baseline record", err))?;
    let temporary = storage.index_baseline_temporary(session_id)?;
    write_json_record_atomically(
        storage,
        &directory,
        &temporary,
        &destination,
        &bytes,
        "index baseline record",
        "cannot sync index baseline record installation",
    )
}

fn remove_index_baseline_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let directory = storage.index_baselines_dir()?;
    let destination = storage.index_baseline_record(session_id)?;
    remove_file_durably_if_present(
        storage,
        &destination,
        &directory,
        "cannot remove index baseline record",
        "cannot sync index baseline record removal",
    )?;
    let temporary = storage.index_baseline_temporary(session_id)?;
    remove_file_durably_if_present(
        storage,
        &temporary,
        &directory,
        "cannot remove temporary index baseline record",
        "cannot sync temporary index baseline record removal",
    )
}

fn create_pending_fork_marker_checked(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let lifecycle_directory = storage.lifecycle_dir()?;
    let directory = storage.pending_forks_dir()?;
    ensure_durable_directory(
        storage,
        storage.root(),
        &lifecycle_directory,
        "cannot create pending fork lifecycle directory",
        "cannot sync pending fork lifecycle directory creation",
    )?;
    ensure_durable_directory(
        storage,
        &lifecycle_directory,
        &directory,
        "cannot create pending fork marker directory",
        "cannot sync pending fork marker directory creation",
    )?;
    let marker = storage.pending_fork_marker(session_id)?;
    storage.validate_regular_file(&marker, true)?;
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker)
        .map_err(|err| engine_err("cannot create pending fork marker", err))?;
    storage.validate_regular_file(&marker, false)?;
    let create_result = (|| -> Result<(), PocketError> {
        file.sync_all()
            .map_err(|err| engine_err("cannot sync pending fork marker", err))?;
        sync_directory(
            storage,
            &directory,
            "cannot sync pending fork marker directory",
        )
    })();
    if let Err(create_err) = create_result {
        return match remove_file_durably_if_present(
            storage,
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

fn ensure_pending_fork_marker_checked(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let marker = storage.pending_fork_marker(session_id)?;
    if storage.validate_regular_file(&marker, true)? {
        storage.validate_regular_file(&marker, false)?;
        std::fs::OpenOptions::new()
            .read(true)
            .open(&marker)
            .and_then(|file| file.sync_all())
            .map_err(|err| engine_err("cannot sync pending fork marker", err))?;
        sync_directory(
            storage,
            &storage.pending_forks_dir()?,
            "cannot sync pending fork marker directory",
        )
    } else {
        create_pending_fork_marker_checked(storage, session_id)
    }
}

fn remove_pending_fork_marker_checked(
    storage: &CheckedStorage,
    session_id: &str,
    missing_ok: bool,
) -> Result<(), PocketError> {
    let directory = storage.pending_forks_dir()?;
    let marker = storage.pending_fork_marker(session_id)?;
    if !storage.validate_regular_file(&marker, true)? {
        if missing_ok {
            return sync_directory_if_present(
                storage,
                &directory,
                "cannot sync absent pending fork marker",
            );
        }
        return Err(engine_err(
            "cannot remove pending fork marker",
            std::io::Error::from(std::io::ErrorKind::NotFound),
        ));
    }
    storage.validate_regular_file(&marker, false)?;
    match std::fs::remove_file(&marker) {
        Ok(()) => {}
        Err(err) if missing_ok && err.kind() == std::io::ErrorKind::NotFound => {
            return sync_directory_if_present(
                storage,
                &directory,
                "cannot sync absent pending fork marker",
            );
        }
        Err(err) => return Err(engine_err("cannot remove pending fork marker", err)),
    }
    sync_directory(
        storage,
        &directory,
        "cannot sync pending fork marker removal",
    )
}

fn pending_fork_ids_checked(storage: &CheckedStorage) -> Result<Vec<String>, PocketError> {
    let directory = storage.pending_forks_dir()?;
    if !storage.validate_directory(&directory, true)? {
        return Ok(Vec::new());
    }
    storage.validate_directory(&directory, false)?;
    let entries = std::fs::read_dir(&directory)
        .map_err(|err| engine_err("cannot read pending fork markers", err))?;
    let mut session_ids = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|err| engine_err("cannot read pending fork marker", err))?;
        let path = entry.path();
        storage.validate_regular_file(&path, false)?;
        let file_name = entry.file_name();
        let file_name = file_name
            .to_str()
            .ok_or_else(|| persistence_err(&path, "pending fork marker name is not valid UTF-8"))?;
        let session_id = file_name.strip_suffix(".pending").ok_or_else(|| {
            persistence_err(
                &path,
                format!("invalid pending fork marker name {file_name:?}"),
            )
        })?;
        validate_session_id(session_id).map_err(|err| {
            persistence_err(
                &path,
                format!("invalid pending fork marker {file_name:?}: {err}"),
            )
        })?;
        session_ids.push(session_id.to_string());
    }
    session_ids.sort();
    Ok(session_ids)
}

fn create_pending_deletion_marker_checked(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let lifecycle_directory = storage.lifecycle_dir()?;
    let directory = storage.pending_deletions_dir()?;
    ensure_durable_directory(
        storage,
        storage.root(),
        &lifecycle_directory,
        "cannot create pending deletion lifecycle directory",
        "cannot sync pending deletion lifecycle directory creation",
    )?;
    ensure_durable_directory(
        storage,
        &lifecycle_directory,
        &directory,
        "cannot create pending deletion marker directory",
        "cannot sync pending deletion marker directory creation",
    )?;
    let marker = storage.pending_deletion_marker(session_id)?;
    storage.validate_regular_file(&marker, true)?;
    #[cfg(test)]
    {
        let mut failures = FILE_CREATE_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(remaining) = failures.get_mut(&marker) {
            if *remaining > 0 {
                *remaining -= 1;
                return Err(engine_err(
                    "cannot create pending deletion marker",
                    std::io::Error::other("injected pending deletion marker creation failure"),
                ));
            }
        }
    }
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker)
        .map_err(|err| engine_err("cannot create pending deletion marker", err))?;
    storage.validate_regular_file(&marker, false)?;
    let create_result = (|| -> Result<(), PocketError> {
        file.sync_all()
            .map_err(|err| engine_err("cannot sync pending deletion marker", err))?;
        sync_directory(
            storage,
            &directory,
            "cannot sync pending deletion marker directory",
        )
    })();
    if let Err(create_err) = create_result {
        return match remove_file_durably_if_present(
            storage,
            &marker,
            &directory,
            "cannot clean pending deletion marker",
            "cannot sync pending deletion marker cleanup",
        ) {
            Ok(()) => Err(create_err),
            Err(cleanup_err) => Err(PocketError::Engine {
                message: format!("{create_err}; cleanup also failed: {cleanup_err}"),
            }),
        };
    }
    Ok(())
}

fn ensure_pending_deletion_marker_checked(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let marker = storage.pending_deletion_marker(session_id)?;
    if storage.validate_regular_file(&marker, true)? {
        storage.validate_regular_file(&marker, false)?;
        std::fs::OpenOptions::new()
            .read(true)
            .open(&marker)
            .and_then(|file| file.sync_all())
            .map_err(|err| engine_err("cannot sync pending deletion marker", err))?;
        sync_directory(
            storage,
            &storage.pending_deletions_dir()?,
            "cannot sync pending deletion marker directory",
        )
    } else {
        create_pending_deletion_marker_checked(storage, session_id)
    }
}

fn remove_pending_deletion_marker_checked(
    storage: &CheckedStorage,
    session_id: &str,
    missing_ok: bool,
) -> Result<(), PocketError> {
    let directory = storage.pending_deletions_dir()?;
    let marker = storage.pending_deletion_marker(session_id)?;
    if !storage.validate_regular_file(&marker, true)? {
        if missing_ok {
            return sync_directory_if_present(
                storage,
                &directory,
                "cannot sync absent pending deletion marker",
            );
        }
        return Err(engine_err(
            "cannot remove pending deletion marker",
            std::io::Error::from(std::io::ErrorKind::NotFound),
        ));
    }
    storage.validate_regular_file(&marker, false)?;
    match remove_file(&marker) {
        Ok(()) => {}
        Err(err) if missing_ok && err.kind() == std::io::ErrorKind::NotFound => {
            return sync_directory_if_present(
                storage,
                &directory,
                "cannot sync absent pending deletion marker",
            );
        }
        Err(err) => return Err(engine_err("cannot remove pending deletion marker", err)),
    }
    sync_directory(
        storage,
        &directory,
        "cannot sync pending deletion marker removal",
    )
}

fn pending_deletion_ids_checked(storage: &CheckedStorage) -> Result<Vec<String>, PocketError> {
    let directory = storage.pending_deletions_dir()?;
    if !storage.validate_directory(&directory, true)? {
        return Ok(Vec::new());
    }
    storage.validate_directory(&directory, false)?;
    let entries = std::fs::read_dir(&directory)
        .map_err(|err| engine_err("cannot read pending deletion markers", err))?;
    let mut session_ids = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|err| engine_err("cannot read pending deletion marker", err))?;
        let path = entry.path();
        storage.validate_regular_file(&path, false)?;
        let file_name = entry.file_name();
        let file_name = file_name.to_str().ok_or_else(|| {
            persistence_err(&path, "pending deletion marker name is not valid UTF-8")
        })?;
        let session_id = file_name.strip_suffix(".pending").ok_or_else(|| {
            persistence_err(
                &path,
                format!("invalid pending deletion marker name {file_name:?}"),
            )
        })?;
        validate_session_id(session_id).map_err(|err| {
            persistence_err(
                &path,
                format!("invalid pending deletion marker {file_name:?}: {err}"),
            )
        })?;
        session_ids.push(session_id.to_string());
    }
    session_ids.sort();
    Ok(session_ids)
}

fn preflight_fork_staging_entries(storage: &CheckedStorage) -> Result<(), PocketError> {
    let stage_root = storage.fork_staging_root()?;
    if !storage.validate_directory(&stage_root, true)? {
        return Ok(());
    }
    storage.validate_directory(&stage_root, false)?;
    let entries = std::fs::read_dir(&stage_root)
        .map_err(|err| engine_err("cannot read fork staging directory", err))?;
    for entry in entries {
        let entry = entry.map_err(|err| engine_err("cannot read fork staging entry", err))?;
        let path = entry.path();
        storage.validate_directory(&path, false)?;
        let file_name = entry.file_name();
        let session_id = file_name
            .to_str()
            .ok_or_else(|| persistence_err(&path, "fork staging ID is not valid UTF-8"))?;
        validate_session_id(session_id).map_err(|err| {
            persistence_err(&path, format!("invalid fork staging session ID: {err}"))
        })?;
        preflight_removal_tree(storage, &path)?;
    }
    Ok(())
}

#[cfg(test)]
fn create_pending_fork_marker(root: &Path, session_id: &str) -> Result<(), PocketError> {
    create_pending_fork_marker_checked(&CheckedStorage::from_root(root)?, session_id)
}

#[cfg(test)]
fn pending_fork_ids(root: &Path) -> Result<Vec<String>, PocketError> {
    pending_fork_ids_checked(&CheckedStorage::from_root(root)?)
}

fn save_familiar_metadata_at_storage(
    storage: &CheckedStorage,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    let destination = storage.familiar_file(session_id)?;
    let metadata_dir = storage.metadata_dir()?;
    let Some(familiar) = familiar else {
        return remove_file_durably_if_present(
            storage,
            &destination,
            &metadata_dir,
            "cannot delete familiar metadata",
            "cannot sync familiar metadata removal",
        );
    };

    let bytes = serde_json::to_vec(familiar)
        .map_err(|err| engine_err("cannot serialize familiar metadata", err))?;
    ensure_durable_directory(
        storage,
        storage.root(),
        &metadata_dir,
        "cannot create metadata dir",
        "cannot sync metadata directory creation",
    )?;
    let temporary = storage.child_path(
        &metadata_dir,
        &format!(".{session_id}.familiar.{}.tmp", uuid::Uuid::new_v4()),
    )?;

    let mut destination_installed = false;
    let write_result = (|| -> Result<(), PocketError> {
        storage
            .validate_regular_file(&temporary, true)
            .map_err(|err| engine_err("cannot create temporary familiar metadata", err))?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|err| engine_err("cannot create temporary familiar metadata", err))?;
        storage
            .validate_regular_file(&temporary, false)
            .map_err(|err| engine_err("cannot create temporary familiar metadata", err))?;
        file.write_all(&bytes)
            .map_err(|err| engine_err("cannot write temporary familiar metadata", err))?;
        file.sync_all()
            .map_err(|err| engine_err("cannot sync temporary familiar metadata", err))?;
        rename_checked_file(
            storage,
            &temporary,
            &destination,
            "cannot install familiar metadata",
        )?;
        destination_installed = true;
        sync_directory(
            storage,
            &metadata_dir,
            "cannot sync installed familiar metadata directory",
        )
    })();

    if let Err(write_err) = write_result {
        let (rollback_path, remove_context, sync_context) = if destination_installed {
            (
                &destination,
                "cannot roll back installed familiar metadata",
                "cannot sync familiar metadata rollback",
            )
        } else {
            (
                &temporary,
                "cannot clean temporary familiar metadata",
                "cannot sync temporary familiar metadata cleanup",
            )
        };
        return match remove_file_durably_if_present(
            storage,
            rollback_path,
            &metadata_dir,
            remove_context,
            sync_context,
        ) {
            Ok(()) => Err(write_err),
            Err(cleanup_err) => Err(PocketError::Engine {
                message: format!("{write_err}; rollback also failed: {cleanup_err}"),
            }),
        };
    }
    Ok(())
}

#[cfg(test)]
fn save_familiar_metadata_at_root(
    root: &Path,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    save_familiar_metadata_at_storage(&CheckedStorage::from_root(root)?, session_id, familiar)
}

/// Atomically save a pinned familiar snapshot, or remove it when absent.
#[cfg(test)]
pub(crate) fn save_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let storage = CheckedStorage::open(storage_dir)?;
    save_familiar_metadata_at_storage(&storage, session_id, familiar)
}

fn load_familiar_metadata_at_storage(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<Option<FamiliarIdentity>, PocketError> {
    let Some(bytes) = familiar_metadata_bytes_at_storage(storage, session_id)? else {
        return Ok(None);
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|err| engine_err("cannot parse familiar metadata", err))
}

fn familiar_metadata_bytes_at_storage(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<Option<Vec<u8>>, PocketError> {
    let path = storage.familiar_file(session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Ok(None);
    }
    storage.validate_regular_file(&path, false)?;
    let bytes = match std::fs::read(&path) {
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
    let storage = CheckedStorage::open(storage_dir)?;
    load_familiar_metadata_at_storage(&storage, session_id)
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
                .take(MAX_SESSION_TITLE_CHARS)
                .collect()
        })
        .unwrap_or_default()
}

/// Append-only persistence for one live session. All calls happen inside a
/// running turn (already serialized by the session's busy flag). Failures are
/// surfaced so the caller can decide to ignore them — a full disk must not
/// take the conversation down.
pub(crate) struct SessionPersistence {
    storage: CheckedStorage,
    key: SessionKey,
    generation: uuid::Uuid,
    _writer_lease: Arc<SessionWriterLease>,
    model: String,
    state: tokio::sync::Mutex<PersistState>,
}

struct PersistState {
    persisted: usize,
    last_uuid: Option<String>,
    pending_index: VecDeque<PendingIndexWork>,
    uncertain_append: Option<String>,
}

struct PendingIndexWork {
    record: PendingIndexRecord,
    appended: bool,
}

impl SessionPersistence {
    pub(crate) async fn create(
        storage_dir: &str,
        session_id: String,
        model: String,
        familiar: Option<&FamiliarIdentity>,
    ) -> Result<Self, PocketError> {
        validate_session_id(&session_id)?;
        let storage = CheckedStorage::open(storage_dir)?;
        let key = session_key(storage.root(), &session_id);
        let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
        recover_storage_unlocked(&storage, &mut lifecycle).await?;
        match lifecycle.sessions.get(&key) {
            Some(SessionLifecycleState::Active { .. }) => {
                return Err(PocketError::Engine {
                    message: format!("generated session id collision: {session_id}"),
                });
            }
            Some(SessionLifecycleState::Tombstoned) => {
                begin_session_deletion(&storage, &session_id)?;
                cleanup_session_artifacts(
                    &storage,
                    &session_id,
                    SessionCleanupMarker::PendingDeletion,
                )
                .map_err(|err| PocketError::Engine {
                    message: format!("cannot clear deleted session before UUID reuse: {err}"),
                })?;
            }
            Some(SessionLifecycleState::PendingFork) => {
                return Err(PocketError::Engine {
                    message: format!("session {session_id} is quarantined pending fork recovery"),
                });
            }
            None => {}
        }
        save_familiar_metadata_at_storage(&storage, &session_id, familiar)?;
        if let Err(model_err) = write_session_model_record(&storage, &session_id, &model) {
            let mut errors = vec![model_err.to_string()];
            if let Err(err) = remove_session_model_artifacts(&storage, &session_id) {
                errors.push(format!("cannot clean session model metadata: {err}"));
            }
            if let Err(err) = save_familiar_metadata_at_storage(&storage, &session_id, None) {
                errors.push(format!("cannot clean familiar metadata: {err}"));
            }
            return Err(PocketError::Engine {
                message: format!(
                    "cannot initialize session model metadata: {}",
                    errors.join("; ")
                ),
            });
        }
        if let Err(baseline_err) = write_index_baseline(&storage, &session_id) {
            let mut errors = vec![baseline_err.to_string()];
            if let Err(err) = remove_index_baseline_artifacts(&storage, &session_id) {
                errors.push(format!("cannot clean index baseline: {err}"));
            }
            if let Err(err) = remove_session_model_artifacts(&storage, &session_id) {
                errors.push(format!("cannot clean session model metadata: {err}"));
            }
            if let Err(err) = save_familiar_metadata_at_storage(&storage, &session_id, None) {
                errors.push(format!("cannot clean familiar metadata: {err}"));
            }
            return Err(PocketError::Engine {
                message: format!(
                    "cannot initialize session index baseline: {}",
                    errors.join("; ")
                ),
            });
        }
        let generation = uuid::Uuid::new_v4();
        let writer_lease = Arc::new(SessionWriterLease);
        lifecycle.sessions.insert(
            key.clone(),
            SessionLifecycleState::Active {
                generation,
                writer: Arc::downgrade(&writer_lease),
            },
        );
        Ok(Self {
            storage,
            key,
            generation,
            _writer_lease: writer_lease,
            model,
            state: tokio::sync::Mutex::new(PersistState {
                persisted: 0,
                last_uuid: None,
                pending_index: VecDeque::new(),
                uncertain_append: None,
            }),
        })
    }

    pub(crate) async fn resume(
        storage_dir: &str,
        session_id: String,
        model: String,
    ) -> Result<(Self, Vec<Message>, Option<FamiliarIdentity>), PocketError> {
        validate_session_id(&session_id)?;
        let storage = CheckedStorage::open(storage_dir)?;
        let key = session_key(storage.root(), &session_id);
        let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
        recover_storage_unlocked(&storage, &mut lifecycle).await?;
        ensure_session_available(&lifecycle, &key)?;
        if matches!(
            lifecycle.sessions.get(&key),
            Some(SessionLifecycleState::Active { writer, .. }) if writer.upgrade().is_some()
        ) {
            return Err(PocketError::Engine {
                message: format!("session {session_id} is already open for writing"),
            });
        }
        let loaded = load_session_transcript_at_storage(&storage, &session_id).await?;
        let store = checked_index_store(&storage)?;
        let baseline = read_index_baseline(&storage, &session_id)?;
        write_session_model_record(&storage, &session_id, &model)?;
        save_index_session(
            &storage,
            &store,
            &session_id,
            Some(&derive_title(&loaded.messages)),
            &model,
            "cannot reconcile session index",
        )?;
        if baseline.is_none() {
            reconcile_loaded_transcript(&storage, &store, &session_id, &loaded)?;
            write_index_baseline(&storage, &session_id)?;
        }
        let last_uuid = loaded.last_uuid();
        let messages = loaded.messages;
        let familiar = load_familiar_metadata_at_storage(&storage, &session_id)?;
        let generation = uuid::Uuid::new_v4();
        let writer_lease = Arc::new(SessionWriterLease);
        lifecycle.sessions.insert(
            key.clone(),
            SessionLifecycleState::Active {
                generation,
                writer: Arc::downgrade(&writer_lease),
            },
        );
        let persistence = Self {
            storage,
            key,
            generation,
            _writer_lease: writer_lease,
            model,
            state: tokio::sync::Mutex::new(PersistState {
                persisted: messages.len(),
                last_uuid,
                pending_index: VecDeque::new(),
                uncertain_append: None,
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
        if let Some(error) = &state.uncertain_append {
            return Err(PocketError::Engine {
                message: format!("append outcome remains uncertain: {error}"),
            });
        }
        if state.pending_index.is_empty() && messages.len() <= state.persisted {
            return Ok(());
        }

        resolve_pending_index_transcript(&self.storage, &mut state).await?;
        let store = checked_index_store(&self.storage)?;
        drain_pending_index(
            &self.storage,
            &store,
            &self.key.session_id,
            &mut state,
            "cannot index message",
        )?;
        if messages.len() <= state.persisted {
            return Ok(());
        }

        let title = derive_title(messages);
        #[cfg(test)]
        if state.persisted == 0 {
            fail_persist_before_first_intent_if_requested(&self.storage)?;
        }
        let path = (|| -> Result<PathBuf, PocketError> {
            let transcript_directory = self.storage.transcripts_dir()?;
            ensure_durable_directory(
                &self.storage,
                self.storage.root(),
                &transcript_directory,
                "cannot create transcript dir",
                "cannot sync transcript directory creation",
            )?;
            let path = self.storage.transcript_file(&self.key.session_id)?;
            self.storage.validate_regular_file(&path, true)?;
            Ok(path)
        })()?;

        while state.persisted < messages.len() {
            let message = &messages[state.persisted];
            let message_uuid = uuid::Uuid::new_v4().to_string();
            let entry = build_entry(
                message.clone(),
                &message_uuid,
                state.last_uuid.as_deref(),
                &self.key.session_id,
            );
            let prepared_append = prepare_transcript_append(&self.storage, &path, &entry)?;
            let record = PendingIndexRecord::from_message(
                &self.key.session_id,
                &message_uuid,
                message,
                &self.model,
                &title,
            );
            if let Err(write_err) = write_pending_index_record(&self.storage, &record) {
                match read_pending_index_record(&self.storage, &self.key.session_id) {
                    Ok(Some(existing)) if existing == record => {
                        state.pending_index.push_back(PendingIndexWork {
                            record,
                            appended: false,
                        });
                        return Err(write_err);
                    }
                    Ok(Some(_)) => return Err(write_err),
                    Ok(None) => return Err(write_err),
                    Err(inspect_err) => {
                        return Err(PocketError::Engine {
                            message: format!(
                                "{write_err}; cannot inspect failed pending index publication: \
                                 {inspect_err}"
                            ),
                        });
                    }
                }
            }
            state.pending_index.push_back(PendingIndexWork {
                record,
                appended: false,
            });
            if let Err(preflight_err) = self.storage.validate_regular_file(&path, true) {
                let record = state
                    .pending_index
                    .back()
                    .map(|work| work.record.clone())
                    .ok_or_else(|| PocketError::Engine {
                        message: "pending index state disappeared before transcript append"
                            .to_string(),
                    })?;
                if let Err(cleanup_err) = remove_pending_index_record(&self.storage, &record, false)
                {
                    return Err(PocketError::Engine {
                        message: format!(
                            "{preflight_err}; cannot clean pending index intent: {cleanup_err}"
                        ),
                    });
                }
                state.pending_index.pop_back();
                return Err(preflight_err);
            }
            if let Err(err) = append_transcript_entry(&self.storage, &path, &prepared_append) {
                let append_err = err.error;
                if err.uncertain {
                    state.uncertain_append = Some(append_err.to_string());
                    return Err(append_err);
                }
                let record = state
                    .pending_index
                    .back()
                    .map(|work| work.record.clone())
                    .ok_or_else(|| PocketError::Engine {
                        message: "pending index state disappeared after failed transcript append"
                            .to_string(),
                    })?;
                if let Err(cleanup_err) = remove_pending_index_record(&self.storage, &record, false)
                {
                    return Err(PocketError::Engine {
                        message: format!(
                            "{append_err}; cannot clean pending index intent: {cleanup_err}"
                        ),
                    });
                }
                state.pending_index.pop_back();
                return Err(append_err);
            }
            let pending = state
                .pending_index
                .back_mut()
                .ok_or_else(|| PocketError::Engine {
                    message: "pending index state disappeared after transcript append".to_string(),
                })?;
            pending.appended = true;
            state.persisted += 1;
            state.last_uuid = Some(message_uuid);
            self.storage.validate_regular_file(&path, false)?;
            drain_pending_index(
                &self.storage,
                &store,
                &self.key.session_id,
                &mut state,
                "cannot index message",
            )?;
        }
        Ok(())
    }
}

impl PendingIndexRecord {
    fn from_message(
        session_id: &str,
        message_uuid: &str,
        message: &Message,
        model: &str,
        title: &str,
    ) -> Self {
        Self {
            version: INDEX_RECORD_VERSION,
            session_id: session_id.to_string(),
            message_uuid: message_uuid.to_string(),
            role: role_str(&message.role).to_string(),
            text: message.get_all_text(),
            model: model.to_string(),
            title: title.to_string(),
        }
    }

    fn from_entry(session_id: &str, entry: &TranscriptEntry) -> Result<Option<Self>, PocketError> {
        let message = match entry {
            TranscriptEntry::User(message) | TranscriptEntry::Assistant(message) => message,
            _ => return Ok(None),
        };
        let message_uuid = message.uuid.clone().ok_or_else(|| PocketError::Engine {
            message: "cannot reconcile transcript message without UUID".to_string(),
        })?;
        Ok(Some(Self::from_message(
            session_id,
            &message_uuid,
            &message.message,
            "",
            "",
        )))
    }

    fn matches_transcript_message(&self, actual: &Self) -> bool {
        self.version == actual.version
            && self.session_id == actual.session_id
            && self.message_uuid == actual.message_uuid
            && self.role == actual.role
            && self.text == actual.text
    }
}

async fn resolve_pending_index_transcript(
    storage: &CheckedStorage,
    state: &mut PersistState,
) -> Result<(), PocketError> {
    while let Some(work) = state.pending_index.front() {
        if work.appended {
            return Ok(());
        }
        let record = work.record.clone();
        match find_pending_index_record_in_transcript(storage, &record).await? {
            PendingTranscriptMatch::TranscriptAbsent
            | PendingTranscriptMatch::TranscriptEmpty
            | PendingTranscriptMatch::MessageAbsent => {
                remove_pending_index_record(storage, &record, true)?;
                state.pending_index.pop_front();
            }
            PendingTranscriptMatch::Present => {
                let work = state
                    .pending_index
                    .front_mut()
                    .ok_or_else(|| PocketError::Engine {
                        message: "pending index state disappeared during recovery".to_string(),
                    })?;
                work.appended = true;
                state.persisted += 1;
                state.last_uuid = Some(record.message_uuid);
                return Ok(());
            }
        }
    }
    Ok(())
}

fn drain_pending_index(
    storage: &CheckedStorage,
    store: &SqliteSessionStore,
    session_id: &str,
    state: &mut PersistState,
    context: &str,
) -> Result<(), PocketError> {
    while let Some(work) = state.pending_index.front() {
        let record = work.record.clone();
        if !work.appended {
            return Err(PocketError::Engine {
                message: format!(
                    "pending index message {} has not been found in the transcript",
                    record.message_uuid
                ),
            });
        }
        if record.session_id != session_id {
            return Err(PocketError::Engine {
                message: format!(
                    "pending index session {} does not match live session {session_id}",
                    record.session_id
                ),
            });
        }
        publish_pending_index_record(storage, store, &record, "cannot index session", context)?;
        remove_pending_index_record(storage, &record, true)?;
        state.pending_index.pop_front();
    }
    Ok(())
}

fn publish_pending_index_record(
    storage: &CheckedStorage,
    store: &SqliteSessionStore,
    record: &PendingIndexRecord,
    session_context: &str,
    message_context: &str,
) -> Result<(), PocketError> {
    save_index_session(
        storage,
        store,
        &record.session_id,
        Some(&record.title),
        &record.model,
        session_context,
    )?;
    save_index_message(
        storage,
        store,
        &record.session_id,
        &record.message_uuid,
        &record.role,
        &record.text,
        message_context,
    )
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

struct LoadedSessionTranscript {
    entries: Vec<TranscriptEntry>,
    messages: Vec<Message>,
}

impl LoadedSessionTranscript {
    fn last_uuid(&self) -> Option<String> {
        self.entries.iter().rev().find_map(|entry| match entry {
            TranscriptEntry::User(message) | TranscriptEntry::Assistant(message) => {
                message.uuid.clone()
            }
            _ => None,
        })
    }
}

async fn load_existing_session_transcript_at_storage(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<Option<LoadedSessionTranscript>, PocketError> {
    let path = storage.transcript_file(session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Ok(None);
    }
    storage.validate_regular_file(&path, false)?;
    repair_incomplete_transcript_tail(storage, &path)?;
    let entries = load_transcript(&path)
        .await
        .map_err(|e| engine_err("cannot load transcript", e))?;
    let messages = messages_from_transcript(&entries);
    Ok(Some(LoadedSessionTranscript { entries, messages }))
}

async fn load_session_transcript_at_storage(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<LoadedSessionTranscript, PocketError> {
    load_existing_session_transcript_at_storage(storage, session_id)
        .await?
        .ok_or_else(|| PocketError::Engine {
            message: format!("no stored session {session_id}"),
        })
}

enum PendingTranscriptMatch {
    TranscriptAbsent,
    TranscriptEmpty,
    MessageAbsent,
    Present,
}

async fn find_pending_index_record_in_transcript(
    storage: &CheckedStorage,
    record: &PendingIndexRecord,
) -> Result<PendingTranscriptMatch, PocketError> {
    let Some(loaded) =
        load_existing_session_transcript_at_storage(storage, &record.session_id).await?
    else {
        return Ok(PendingTranscriptMatch::TranscriptAbsent);
    };
    if loaded.entries.is_empty() {
        return Ok(PendingTranscriptMatch::TranscriptEmpty);
    }
    let mut found = false;
    for entry in &loaded.entries {
        if entry.uuid() != Some(record.message_uuid.as_str()) {
            continue;
        }
        if found {
            return Err(PocketError::Engine {
                message: format!(
                    "pending index message UUID {} appears more than once in session {}",
                    record.message_uuid, record.session_id
                ),
            });
        }
        let transcript_message = match entry {
            TranscriptEntry::User(message) | TranscriptEntry::Assistant(message) => message,
            _ => {
                return Err(PocketError::Engine {
                    message: format!(
                        "pending index message UUID {} is not a user or assistant entry",
                        record.message_uuid
                    ),
                });
            }
        };
        if transcript_message.session_id != record.session_id {
            return Err(PocketError::Engine {
                message: format!(
                    "pending index record mismatch: transcript session {} does not match {}",
                    transcript_message.session_id, record.session_id
                ),
            });
        }
        let actual =
            PendingIndexRecord::from_entry(&record.session_id, entry)?.ok_or_else(|| {
                PocketError::Engine {
                    message: "pending index transcript entry has no indexable message".to_string(),
                }
            })?;
        if !record.matches_transcript_message(&actual) {
            return Err(PocketError::Engine {
                message: format!(
                    "pending index record mismatch for message {} in session {}",
                    record.message_uuid, record.session_id
                ),
            });
        }
        found = true;
    }
    Ok(if found {
        PendingTranscriptMatch::Present
    } else {
        PendingTranscriptMatch::MessageAbsent
    })
}

fn reconcile_loaded_transcript(
    storage: &CheckedStorage,
    store: &SqliteSessionStore,
    session_id: &str,
    loaded: &LoadedSessionTranscript,
) -> Result<(), PocketError> {
    for entry in &loaded.entries {
        if let Some(message) = PendingIndexRecord::from_entry(session_id, entry)? {
            save_index_message(
                storage,
                store,
                session_id,
                &message.message_uuid,
                &message.role,
                &message.text,
                "cannot reconcile message index",
            )?;
        }
    }
    Ok(())
}

struct PendingIndexRecoveryPlan {
    records: Vec<PendingIndexRecord>,
    oversized_records: Vec<OversizedPendingIndexRecord>,
    temporary_files: Vec<PathBuf>,
}

struct OversizedPendingIndexRecord {
    session_id: String,
    size: u64,
}

struct StorageRecoveryPlan {
    lifecycle: PendingLifecycleRecoveryPlan,
    pending_index: PendingIndexRecoveryPlan,
}

fn preflight_pending_index_recovery(
    storage: &CheckedStorage,
) -> Result<PendingIndexRecoveryPlan, PocketError> {
    let directory = storage.pending_index_dir()?;
    if !storage.validate_directory(&directory, true)? {
        return Ok(PendingIndexRecoveryPlan {
            records: Vec::new(),
            oversized_records: Vec::new(),
            temporary_files: Vec::new(),
        });
    }
    storage.validate_directory(&directory, false)?;
    let entries = std::fs::read_dir(&directory)
        .map_err(|err| engine_err("cannot read pending index directory", err))?;
    let mut records = Vec::new();
    let mut oversized_records = Vec::new();
    let mut temporary_files = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|err| engine_err("cannot read pending index entry", err))?;
        let path = entry.path();
        storage.validate_regular_file(&path, false)?;
        let size = std::fs::symlink_metadata(&path)
            .map_err(|err| engine_err("cannot inspect pending index entry", err))?
            .len();
        let file_name = entry.file_name();
        let file_name = file_name
            .to_str()
            .ok_or_else(|| persistence_err(&path, "pending index name is not valid UTF-8"))?;
        if let Some(session_id) = file_name
            .strip_prefix('.')
            .and_then(|name| name.strip_suffix(".json.tmp"))
        {
            validate_session_id(session_id).map_err(|err| {
                persistence_err(
                    &path,
                    format!("invalid temporary pending index record name: {err}"),
                )
            })?;
            temporary_files.push(path);
            continue;
        }
        let session_id = file_name.strip_suffix(".json").ok_or_else(|| {
            persistence_err(
                &path,
                format!("invalid pending index record name {file_name:?}"),
            )
        })?;
        validate_session_id(session_id).map_err(|err| {
            persistence_err(
                &path,
                format!("invalid pending index record name {file_name:?}: {err}"),
            )
        })?;
        // Records above the historical read cap may be remnants of the wedge.
        // Recover them from the transcript without parsing their contents,
        // including newly valid records in the widened metadata allowance.
        if size > MAX_LEGACY_INDEX_RECORD_BYTES {
            oversized_records.push(OversizedPendingIndexRecord {
                session_id: session_id.to_string(),
                size,
            });
            continue;
        }
        let record = read_json_record(
            storage,
            &path,
            MAX_INDEX_RECORD_BYTES,
            "cannot parse pending index record",
        )?;
        validate_pending_index_record(&record, &path, session_id)?;
        records.push(record);
    }
    records.sort_by(|left, right| left.session_id.cmp(&right.session_id));
    oversized_records.sort_by(|left, right| left.session_id.cmp(&right.session_id));
    temporary_files.sort();

    for session_id in records
        .iter()
        .map(|record| record.session_id.as_str())
        .chain(
            oversized_records
                .iter()
                .map(|record| record.session_id.as_str()),
        )
    {
        preflight_session_artifacts(storage, session_id)?;
    }
    for record in &oversized_records {
        read_session_model_record(storage, &record.session_id)?;
        read_index_baseline(storage, &record.session_id)?;
    }
    Ok(PendingIndexRecoveryPlan {
        records,
        oversized_records,
        temporary_files,
    })
}

fn preflight_storage_recovery(
    storage: &CheckedStorage,
    lifecycle: &SessionLifecycle,
) -> Result<StorageRecoveryPlan, PocketError> {
    let lifecycle_plan = preflight_pending_lifecycle_recovery(storage, lifecycle)?;
    let pending_index = preflight_pending_index_recovery(storage)?;
    Ok(StorageRecoveryPlan {
        lifecycle: lifecycle_plan,
        pending_index,
    })
}

fn verify_oversized_pending_index_record(
    storage: &CheckedStorage,
    record: &OversizedPendingIndexRecord,
) -> Result<Option<PathBuf>, PocketError> {
    let path = storage.pending_index_record(&record.session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Ok(None);
    }
    let size = std::fs::symlink_metadata(&path)
        .map_err(|err| engine_err("cannot inspect oversized pending index record", err))?
        .len();
    if size <= MAX_LEGACY_INDEX_RECORD_BYTES {
        return Err(persistence_err(
            &path,
            format!(
                "legacy-oversized pending index record changed size before recovery ({size} bytes)"
            ),
        ));
    }
    if size != record.size {
        return Err(persistence_err(
            &path,
            format!(
                "oversized pending index record changed during recovery preflight ({} to {size} \
                 bytes)",
                record.size
            ),
        ));
    }
    Ok(Some(path))
}

fn remove_oversized_pending_index_record(
    storage: &CheckedStorage,
    record: &OversizedPendingIndexRecord,
) -> Result<(), PocketError> {
    let Some(path) = verify_oversized_pending_index_record(storage, record)? else {
        return Ok(());
    };
    let directory = storage.pending_index_dir()?;
    remove_file_durably_if_present(
        storage,
        &path,
        &directory,
        "cannot remove oversized pending index marker",
        "cannot sync oversized pending index marker removal",
    )
}

fn recover_absent_oversized_pending_index_record(
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
    record: &OversizedPendingIndexRecord,
) -> Result<(), PocketError> {
    begin_session_deletion_and_tombstone(storage, lifecycle, &record.session_id)?;
    cleanup_session_artifacts(
        storage,
        &record.session_id,
        SessionCleanupMarker::PendingDeletion,
    )
    .map_err(|err| PocketError::Engine {
        message: format!(
            "cannot recover session {} without a durable transcript from oversized pending index \
             marker: {err}",
            record.session_id
        ),
    })
}

fn recover_oversized_pending_index_transcript(
    storage: &CheckedStorage,
    record: &OversizedPendingIndexRecord,
    loaded: &LoadedSessionTranscript,
) -> Result<(), PocketError> {
    let model = read_session_model_record(storage, &record.session_id)?
        .map(|record| record.model)
        .ok_or_else(|| PocketError::Engine {
            message: format!(
                "cannot safely recover session {} with oversized pending index marker without \
                 trusted model metadata",
                record.session_id
            ),
        })?;
    write_session_model_record(storage, &record.session_id, &model)?;
    remove_index_baseline_artifacts(storage, &record.session_id)?;
    delete_index_session(
        storage,
        &record.session_id,
        "cannot reset oversized pending session index",
    )?;
    let store = checked_index_store(storage)?;
    save_index_session(
        storage,
        &store,
        &record.session_id,
        Some(&derive_title(&loaded.messages)),
        &model,
        "cannot recover oversized pending session index",
    )?;
    for entry in &loaded.entries {
        if let Some(message) = PendingIndexRecord::from_entry(&record.session_id, entry)? {
            save_index_message(
                storage,
                &store,
                &record.session_id,
                &message.message_uuid,
                &message.role,
                &message.text,
                "cannot recover oversized pending message index",
            )?;
        }
    }
    write_index_baseline(storage, &record.session_id)?;
    remove_oversized_pending_index_record(storage, record)
}

async fn recover_pending_index_plan(
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
    plan: PendingIndexRecoveryPlan,
) -> Result<(), PocketError> {
    let PendingIndexRecoveryPlan {
        records,
        oversized_records,
        temporary_files,
    } = plan;
    let directory = storage.pending_index_dir()?;
    for record in oversized_records {
        if verify_oversized_pending_index_record(storage, &record)?.is_none() {
            continue;
        }
        if matches!(
            lifecycle
                .sessions
                .get(&session_key(storage.root(), &record.session_id)),
            Some(SessionLifecycleState::Tombstoned | SessionLifecycleState::PendingFork)
        ) {
            remove_oversized_pending_index_record(storage, &record)?;
            continue;
        }
        match load_existing_session_transcript_at_storage(storage, &record.session_id).await? {
            None => {
                recover_absent_oversized_pending_index_record(storage, lifecycle, &record)?;
            }
            Some(loaded) if loaded.entries.is_empty() => {
                recover_absent_oversized_pending_index_record(storage, lifecycle, &record)?;
            }
            Some(loaded) => {
                recover_oversized_pending_index_transcript(storage, &record, &loaded)?;
            }
        }
    }
    for temporary in temporary_files {
        remove_file_durably_if_present(
            storage,
            &temporary,
            &directory,
            "cannot remove incomplete temporary pending index record",
            "cannot sync incomplete temporary pending index record removal",
        )?;
    }

    for record in records {
        if read_pending_index_record(storage, &record.session_id)?.is_none() {
            continue;
        }
        if matches!(
            lifecycle
                .sessions
                .get(&session_key(storage.root(), &record.session_id)),
            Some(SessionLifecycleState::Tombstoned | SessionLifecycleState::PendingFork)
        ) {
            remove_pending_index_record(storage, &record, false)?;
            continue;
        }
        match find_pending_index_record_in_transcript(storage, &record).await? {
            PendingTranscriptMatch::TranscriptAbsent | PendingTranscriptMatch::TranscriptEmpty => {
                recover_absent_pending_index_record(storage, lifecycle, &record)?;
            }
            PendingTranscriptMatch::MessageAbsent => {
                remove_pending_index_record(storage, &record, false)?;
            }
            PendingTranscriptMatch::Present => {
                {
                    let index_store = checked_index_store(storage)?;
                    publish_pending_index_record(
                        storage,
                        &index_store,
                        &record,
                        "cannot recover pending session index",
                        "cannot recover pending message index",
                    )?;
                }
                remove_pending_index_record(storage, &record, false)?;
            }
        }
    }
    Ok(())
}

enum AbsentPendingIndexRecovery {
    RemoveIntentOnly,
    DeleteUnpublishedSession,
}

fn classify_absent_pending_index_recovery(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<AbsentPendingIndexRecovery, PocketError> {
    let store = checked_index_store(storage)?;
    storage.validate_sqlite_files()?;
    let rows = store
        .list_sessions()
        .map_err(|err| engine_err("cannot inspect speculative session index", err))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    Ok(
        if rows
            .iter()
            .any(|row| row.id == session_id && row.message_count == 0)
        {
            AbsentPendingIndexRecovery::DeleteUnpublishedSession
        } else {
            AbsentPendingIndexRecovery::RemoveIntentOnly
        },
    )
}

fn recover_absent_pending_index_record(
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
    record: &PendingIndexRecord,
) -> Result<(), PocketError> {
    match classify_absent_pending_index_recovery(storage, &record.session_id)? {
        AbsentPendingIndexRecovery::RemoveIntentOnly => {
            remove_pending_index_record(storage, record, false)
        }
        AbsentPendingIndexRecovery::DeleteUnpublishedSession => {
            begin_session_deletion_and_tombstone(storage, lifecycle, &record.session_id)?;
            cleanup_session_artifacts(
                storage,
                &record.session_id,
                SessionCleanupMarker::PendingDeletion,
            )
            .map_err(|err| PocketError::Engine {
                message: format!(
                    "cannot recover unpublished first-turn session {}: {err}",
                    record.session_id
                ),
            })
        }
    }
}

async fn recover_storage_unlocked(
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
) -> Result<(), PocketError> {
    let plan = preflight_storage_recovery(storage, lifecycle)?;
    recover_pending_lifecycle_plan(storage, lifecycle, plan.lifecycle)?;
    recover_pending_index_plan(storage, lifecycle, plan.pending_index).await
}

#[cfg(test)]
async fn load_session_messages_at_root(
    root: &Path,
    session_id: &str,
) -> Result<(Vec<Message>, Option<String>), PocketError> {
    let loaded =
        load_session_transcript_at_storage(&CheckedStorage::from_root(root)?, session_id).await?;
    let last_uuid = loaded.last_uuid();
    Ok((loaded.messages, last_uuid))
}

/// Newest-first summaries for the browser.
pub async fn list_sessions(storage_dir: &str) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let storage = CheckedStorage::open(storage_dir)?;
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_storage_unlocked(&storage, &mut lifecycle).await?;
    list_sessions_unlocked(&storage, &lifecycle)
}

fn list_sessions_unlocked(
    storage: &CheckedStorage,
    lifecycle: &SessionLifecycle,
) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let store = checked_index_store(storage)?;
    storage.validate_sqlite_files()?;
    let rows = store
        .list_sessions()
        .map_err(|e| engine_err("cannot list sessions", e))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    rows.into_iter()
        .filter(|session| {
            !matches!(
                lifecycle
                    .sessions
                    .get(&session_key(storage.root(), &session.id)),
                Some(SessionLifecycleState::Tombstoned | SessionLifecycleState::PendingFork)
            )
        })
        .map(|s| {
            let familiar = load_familiar_metadata_at_storage(storage, &s.id)?;
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

struct SessionArtifactPreflight {
    transcript_exists: bool,
    familiar_exists: bool,
    stage_exists: bool,
    pending_fork_marker_exists: bool,
    pending_deletion_marker_exists: bool,
    pending_index_record_exists: bool,
    pending_index_temporary_exists: bool,
    session_model_record_exists: bool,
    session_model_temporary_exists: bool,
    index_baseline_record_exists: bool,
    index_baseline_temporary_exists: bool,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SessionCleanupMarker {
    PendingDeletion,
    PendingFork,
}

impl SessionArtifactPreflight {
    fn marker_exists(&self, marker: SessionCleanupMarker) -> bool {
        match marker {
            SessionCleanupMarker::PendingDeletion => self.pending_deletion_marker_exists,
            SessionCleanupMarker::PendingFork => self.pending_fork_marker_exists,
        }
    }
}

fn preflight_session_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<SessionArtifactPreflight, PocketError> {
    validate_session_id(session_id)?;
    storage.validate_fixed_layout()?;
    storage.validate_sqlite_files()?;
    let transcript_exists =
        storage.validate_regular_file(&storage.transcript_file(session_id)?, true)?;
    let familiar_exists =
        storage.validate_regular_file(&storage.familiar_file(session_id)?, true)?;
    let pending_fork_marker_exists =
        storage.validate_regular_file(&storage.pending_fork_marker(session_id)?, true)?;
    let pending_deletion_marker_exists =
        storage.validate_regular_file(&storage.pending_deletion_marker(session_id)?, true)?;
    let pending_index_record_exists =
        storage.validate_regular_file(&storage.pending_index_record(session_id)?, true)?;
    let pending_index_temporary_exists =
        storage.validate_regular_file(&storage.pending_index_temporary(session_id)?, true)?;
    let session_model_record_exists =
        storage.validate_regular_file(&storage.session_model_record(session_id)?, true)?;
    let session_model_temporary_exists =
        storage.validate_regular_file(&storage.session_model_temporary(session_id)?, true)?;
    let index_baseline_record_exists =
        storage.validate_regular_file(&storage.index_baseline_record(session_id)?, true)?;
    let index_baseline_temporary_exists =
        storage.validate_regular_file(&storage.index_baseline_temporary(session_id)?, true)?;
    let stage_directory = storage.fork_staging_dir(session_id)?;
    let stage_exists = preflight_removal_tree(storage, &stage_directory)?.is_some();
    Ok(SessionArtifactPreflight {
        transcript_exists,
        familiar_exists,
        stage_exists,
        pending_fork_marker_exists,
        pending_deletion_marker_exists,
        pending_index_record_exists,
        pending_index_temporary_exists,
        session_model_record_exists,
        session_model_temporary_exists,
        index_baseline_record_exists,
        index_baseline_temporary_exists,
    })
}

fn ensure_cleanup_marker(
    storage: &CheckedStorage,
    session_id: &str,
    marker: SessionCleanupMarker,
) -> Result<(), PocketError> {
    match marker {
        SessionCleanupMarker::PendingDeletion => {
            ensure_pending_deletion_marker_checked(storage, session_id)
        }
        SessionCleanupMarker::PendingFork => {
            ensure_pending_fork_marker_checked(storage, session_id)
        }
    }
}

fn remove_cleanup_marker(
    storage: &CheckedStorage,
    session_id: &str,
    marker: SessionCleanupMarker,
) -> Result<(), PocketError> {
    match marker {
        SessionCleanupMarker::PendingDeletion => {
            remove_pending_deletion_marker_checked(storage, session_id, false)
        }
        SessionCleanupMarker::PendingFork => {
            remove_pending_fork_marker_checked(storage, session_id, false)
        }
    }
}

fn cleanup_error(
    storage: &CheckedStorage,
    session_id: &str,
    marker: SessionCleanupMarker,
    mut errors: Vec<String>,
) -> PocketError {
    if let Err(err) = ensure_cleanup_marker(storage, session_id, marker) {
        errors.push(format!("cannot preserve cleanup marker: {err}"));
    }
    PocketError::Engine {
        message: format!("cannot delete all session artifacts: {}", errors.join("; ")),
    }
}

fn verify_session_artifacts_absent(
    storage: &CheckedStorage,
    session_id: &str,
    marker: SessionCleanupMarker,
) -> Result<(), PocketError> {
    let preflight = preflight_session_artifacts(storage, session_id)?;
    if !preflight.marker_exists(marker) {
        return Err(PocketError::Engine {
            message: format!("cleanup marker for session {session_id} is missing"),
        });
    }
    let rows = checked_index_store(storage)?
        .list_sessions()
        .map_err(|err| engine_err("cannot verify deleted session index", err))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    if rows.iter().any(|row| row.id == session_id) {
        return Err(PocketError::Engine {
            message: format!("session {session_id} remains in the session index"),
        });
    }
    if preflight.transcript_exists {
        return Err(PocketError::Engine {
            message: format!("transcript for session {session_id} remains after cleanup"),
        });
    }
    if preflight.familiar_exists {
        return Err(PocketError::Engine {
            message: format!("familiar metadata for session {session_id} remains after cleanup"),
        });
    }
    if preflight.stage_exists {
        return Err(PocketError::Engine {
            message: format!("fork staging for session {session_id} remains after cleanup"),
        });
    }
    if preflight.pending_index_record_exists || preflight.pending_index_temporary_exists {
        return Err(PocketError::Engine {
            message: format!("pending message index recovery for session {session_id} remains"),
        });
    }
    if preflight.session_model_record_exists || preflight.session_model_temporary_exists {
        return Err(PocketError::Engine {
            message: format!("session model metadata for session {session_id} remains"),
        });
    }
    if preflight.index_baseline_record_exists || preflight.index_baseline_temporary_exists {
        return Err(PocketError::Engine {
            message: format!("index baseline for session {session_id} remains"),
        });
    }
    if marker == SessionCleanupMarker::PendingDeletion && preflight.pending_fork_marker_exists {
        return Err(PocketError::Engine {
            message: format!("pending fork marker for session {session_id} remains after cleanup"),
        });
    }
    Ok(())
}

fn begin_session_deletion(storage: &CheckedStorage, session_id: &str) -> Result<(), PocketError> {
    let preflight = preflight_session_artifacts(storage, session_id)?;
    if preflight.pending_deletion_marker_exists {
        ensure_pending_deletion_marker_checked(storage, session_id)
    } else {
        create_pending_deletion_marker_checked(storage, session_id)
    }
}

fn begin_session_deletion_and_tombstone(
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
    session_id: &str,
) -> Result<(), PocketError> {
    let key = session_key(storage.root(), session_id);
    if let Err(start_err) = begin_session_deletion(storage, session_id) {
        let marker_state = storage
            .pending_deletion_marker(session_id)
            .and_then(|marker| storage.validate_regular_file(&marker, true));
        match marker_state {
            Ok(true) => {
                lifecycle
                    .sessions
                    .insert(key, SessionLifecycleState::Tombstoned);
            }
            Ok(false) => {}
            Err(marker_err) => {
                lifecycle
                    .sessions
                    .insert(key, SessionLifecycleState::Tombstoned);
                return Err(PocketError::Engine {
                    message: format!(
                        "{start_err}; cannot verify failed pending deletion marker rollback: \
                         {marker_err}"
                    ),
                });
            }
        }
        return Err(start_err);
    }
    lifecycle
        .sessions
        .insert(key, SessionLifecycleState::Tombstoned);
    Ok(())
}

fn cleanup_session_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
    marker: SessionCleanupMarker,
) -> Result<(), PocketError> {
    ensure_cleanup_marker(storage, session_id, marker)?;
    let preflight = preflight_session_artifacts(storage, session_id)?;
    if marker == SessionCleanupMarker::PendingFork && preflight.pending_deletion_marker_exists {
        return Err(PocketError::Engine {
            message: format!(
                "pending deletion supersedes pending fork cleanup for session {session_id}"
            ),
        });
    }
    let mut marker_errors = Vec::new();
    if let Err(err) = remove_pending_index_artifacts(storage, session_id) {
        marker_errors.push(err.to_string());
    }
    if let Err(err) = remove_index_baseline_artifacts(storage, session_id) {
        marker_errors.push(err.to_string());
    }
    if let Err(err) = remove_session_model_artifacts(storage, session_id) {
        marker_errors.push(err.to_string());
    }
    if !marker_errors.is_empty() {
        return Err(cleanup_error(storage, session_id, marker, marker_errors));
    }
    if let Err(err) = delete_index_session(storage, session_id, "cannot delete session index") {
        return Err(cleanup_error(
            storage,
            session_id,
            marker,
            vec![err.to_string()],
        ));
    }

    let mut errors = Vec::new();
    let transcript_directory = storage.transcripts_dir()?;
    let transcript = storage.transcript_file(session_id)?;
    if let Err(err) = remove_file_durably_if_present(
        storage,
        &transcript,
        &transcript_directory,
        "cannot delete transcript",
        "cannot sync transcript removal",
    ) {
        errors.push(err.to_string());
    }
    if let Err(err) = save_familiar_metadata_at_storage(storage, session_id, None) {
        errors.push(err.to_string());
    }
    if let Err(err) = remove_fork_staging_artifacts(storage, session_id) {
        errors.push(err.to_string());
    }
    if marker == SessionCleanupMarker::PendingDeletion {
        if let Err(err) = remove_pending_fork_marker_checked(storage, session_id, true) {
            errors.push(err.to_string());
        }
    }
    if !errors.is_empty() {
        return Err(cleanup_error(storage, session_id, marker, errors));
    }
    if let Err(err) = verify_session_artifacts_absent(storage, session_id, marker) {
        return Err(cleanup_error(
            storage,
            session_id,
            marker,
            vec![err.to_string()],
        ));
    }
    if let Err(err) = remove_cleanup_marker(storage, session_id, marker) {
        return Err(cleanup_error(
            storage,
            session_id,
            marker,
            vec![err.to_string()],
        ));
    }
    Ok(())
}

struct PendingLifecycleRecoveryPlan {
    pending_deletion_ids: Vec<String>,
    pending_fork_ids: Vec<String>,
}

fn preflight_pending_lifecycle_recovery(
    storage: &CheckedStorage,
    lifecycle: &SessionLifecycle,
) -> Result<PendingLifecycleRecoveryPlan, PocketError> {
    let pending_deletion_ids = pending_deletion_ids_checked(storage)?;
    let pending_fork_ids = pending_fork_ids_checked(storage)?;
    preflight_fork_staging_entries(storage)?;
    let mut pending_ids = pending_deletion_ids.clone();
    for session_id in &pending_fork_ids {
        if !pending_ids.contains(session_id) {
            pending_ids.push(session_id.clone());
        }
    }
    pending_ids.sort();
    for session_id in &pending_ids {
        preflight_session_artifacts(storage, session_id)?;
    }
    if let Some(key) = lifecycle.sessions.keys().find(|key| {
        key.root == storage.root()
            && matches!(
                lifecycle.sessions.get(*key),
                Some(SessionLifecycleState::PendingFork)
            )
            && !pending_fork_ids.contains(&key.session_id)
            && !pending_deletion_ids.contains(&key.session_id)
    }) {
        return Err(PocketError::Engine {
            message: format!(
                "cannot recover pending fork {}: persistent marker is missing",
                key.session_id
            ),
        });
    }
    Ok(PendingLifecycleRecoveryPlan {
        pending_deletion_ids,
        pending_fork_ids,
    })
}

fn recover_pending_lifecycle_plan(
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
    plan: PendingLifecycleRecoveryPlan,
) -> Result<(), PocketError> {
    for session_id in &plan.pending_deletion_ids {
        lifecycle.sessions.insert(
            session_key(storage.root(), session_id),
            SessionLifecycleState::Tombstoned,
        );
    }
    for session_id in &plan.pending_fork_ids {
        if plan.pending_deletion_ids.contains(session_id) {
            continue;
        }
        let key = session_key(storage.root(), session_id);
        lifecycle
            .sessions
            .insert(key.clone(), SessionLifecycleState::PendingFork);
    }

    for session_id in &plan.pending_deletion_ids {
        if let Err(err) =
            cleanup_session_artifacts(storage, session_id, SessionCleanupMarker::PendingDeletion)
        {
            return Err(PocketError::Engine {
                message: format!("cannot recover pending deletion {session_id}: {err}"),
            });
        }
    }

    for session_id in &plan.pending_fork_ids {
        if plan.pending_deletion_ids.contains(session_id) {
            continue;
        }
        let key = session_key(storage.root(), session_id);
        if let Err(err) =
            cleanup_session_artifacts(storage, session_id, SessionCleanupMarker::PendingFork)
        {
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

/// Drop a session from the index and delete its persisted artifacts.
pub async fn delete_session(storage_dir: &str, session_id: &str) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let storage = CheckedStorage::open(storage_dir)?;
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    let recovery = preflight_storage_recovery(&storage, &lifecycle)?;
    recover_pending_lifecycle_plan(&storage, &mut lifecycle, recovery.lifecycle)?;
    let target_temporary = storage.pending_index_temporary(session_id)?;
    let remaining_pending_index = PendingIndexRecoveryPlan {
        records: recovery
            .pending_index
            .records
            .into_iter()
            .filter(|record| record.session_id != session_id)
            .collect(),
        oversized_records: recovery
            .pending_index
            .oversized_records
            .into_iter()
            .filter(|record| record.session_id != session_id)
            .collect(),
        temporary_files: recovery
            .pending_index
            .temporary_files
            .into_iter()
            .filter(|path| *path != target_temporary)
            .collect(),
    };
    recover_pending_index_plan(&storage, &mut lifecycle, remaining_pending_index).await?;
    begin_session_deletion_and_tombstone(&storage, &mut lifecycle, session_id)?;
    cleanup_session_artifacts(&storage, session_id, SessionCleanupMarker::PendingDeletion)
}

/// Copy a session's transcript under a fresh id at its current head.
/// Returns the new session id.
pub async fn fork_session(storage_dir: &str, session_id: &str) -> Result<String, PocketError> {
    validate_session_id(session_id)?;
    let storage = CheckedStorage::open(storage_dir)?;
    let key = session_key(storage.root(), session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_storage_unlocked(&storage, &mut lifecycle).await?;
    ensure_session_available(&lifecycle, &key)?;
    fork_session_unlocked(&storage, session_id, &mut lifecycle, None).await
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
    let storage = CheckedStorage::open(storage_dir)?;
    let key = session_key(storage.root(), session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_storage_unlocked(&storage, &mut lifecycle).await?;
    ensure_session_available(&lifecycle, &key)?;
    fork_session_unlocked(&storage, session_id, &mut lifecycle, Some(stage_pause)).await
}

struct ForkStage {
    storage: CheckedStorage,
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
    fn begin(storage: &CheckedStorage, new_id: &str) -> Result<Self, PocketError> {
        let directory = storage.fork_staging_dir(new_id)?;
        create_pending_fork_marker_checked(storage, new_id)?;
        Ok(Self {
            storage: storage.clone(),
            session_id: new_id.to_string(),
            transcript: storage.child_path(&directory, &format!("{new_id}.jsonl"))?,
            metadata: None,
            directory,
            published_transcript: None,
            published_metadata: None,
            pending_marker: Some(storage.pending_fork_marker(new_id)?),
            index_may_exist: false,
            staging_may_exist: false,
            armed: true,
        })
    }

    fn create_staging_directory(&mut self) -> Result<(), PocketError> {
        let stage_root = self.storage.fork_staging_root()?;
        ensure_durable_directory(
            &self.storage,
            self.storage.root(),
            &stage_root,
            "cannot create fork staging root",
            "cannot sync fork staging root creation",
        )?;
        self.storage.validate_directory(&self.directory, true)?;
        self.staging_may_exist = true;
        std::fs::create_dir(&self.directory)
            .map_err(|err| engine_err("cannot create fork staging directory", err))?;
        self.storage.validate_directory(&self.directory, false)?;
        sync_directory(
            &self.storage,
            &stage_root,
            "cannot sync fork staging directory creation",
        )
    }

    #[cfg(test)]
    fn create(root: &Path, new_id: &str) -> Result<Self, PocketError> {
        let storage = CheckedStorage::from_root(root)?;
        let mut stage = Self::begin(&storage, new_id)?;
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
        let storage = self.storage.clone();
        self.stage_metadata_with(bytes, |path, bytes, context| {
            write_new_file(&storage, path, bytes, context)
        })
    }

    fn stage_metadata_with(
        &mut self,
        bytes: &[u8],
        write: impl FnOnce(&Path, &[u8], &str) -> Result<(), PocketError>,
    ) -> Result<(), PocketError> {
        let metadata = self.storage.child_path(
            &self.directory,
            &format!("{}.familiar.json", self.session_id),
        )?;
        self.storage.validate_regular_file(&metadata, true)?;
        self.metadata = Some(metadata.clone());
        let result = write(&metadata, bytes, "staged fork familiar metadata");
        if result.is_ok() {
            self.storage.validate_regular_file(&metadata, false)?;
        }
        result
    }

    fn remove_pending_marker_for_commit(&mut self) -> Result<(), PocketError> {
        remove_pending_fork_marker_checked(&self.storage, &self.session_id, false)?;
        self.pending_marker = None;
        Ok(())
    }

    fn cleanup(&mut self) -> Result<(), PocketError> {
        if !self.armed {
            return Ok(());
        }
        let preflight = preflight_session_artifacts(&self.storage, &self.session_id)?;
        if preflight.pending_deletion_marker_exists {
            self.armed = false;
            return Err(PocketError::Engine {
                message: format!(
                    "pending deletion supersedes fork cleanup for session {}",
                    self.session_id
                ),
            });
        }
        let mut errors = Vec::new();
        if let Err(err) = remove_pending_index_artifacts(&self.storage, &self.session_id) {
            errors.push(err.to_string());
        }
        if let Err(err) = remove_index_baseline_artifacts(&self.storage, &self.session_id) {
            errors.push(err.to_string());
        }
        if let Err(err) = remove_session_model_artifacts(&self.storage, &self.session_id) {
            errors.push(err.to_string());
        }
        if self.index_may_exist {
            if self.pending_marker.is_some() {
                if let Err(err) =
                    ensure_pending_fork_marker_checked(&self.storage, &self.session_id)
                {
                    errors.push(err.to_string());
                }
            }
            match delete_index_session(&self.storage, &self.session_id, "cannot clean fork index") {
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
        let metadata_directory = self.storage.metadata_dir()?;
        let transcript_directory = self.storage.transcripts_dir()?;
        for (path, directory, remove_context, sync_context) in [
            (
                self.published_metadata.take(),
                metadata_directory,
                "cannot clean published fork metadata",
                "cannot sync published fork metadata cleanup",
            ),
            (
                self.published_transcript.take(),
                transcript_directory,
                "cannot clean published fork transcript",
                "cannot sync published fork transcript cleanup",
            ),
        ] {
            if let Some(path) = path {
                if let Err(err) = remove_file_durably_if_present(
                    &self.storage,
                    &path,
                    &directory,
                    remove_context,
                    sync_context,
                ) {
                    errors.push(err.to_string());
                }
            }
        }
        self.metadata = None;
        if self.staging_may_exist {
            if let Err(err) = remove_fork_staging_artifacts(&self.storage, &self.session_id) {
                errors.push(err.to_string());
            } else {
                self.staging_may_exist = false;
            }
        } else if let Err(err) = remove_empty_fork_staging_root(&self.storage) {
            errors.push(err.to_string());
        }
        if errors.is_empty() && self.pending_marker.is_some() {
            match remove_pending_fork_marker_checked(&self.storage, &self.session_id, true) {
                Ok(()) => self.pending_marker = None,
                Err(err) => {
                    errors.push(err.to_string());
                    if let Err(restore_err) =
                        ensure_pending_fork_marker_checked(&self.storage, &self.session_id)
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
        let stage_root = self.storage.fork_staging_root()?;
        remove_dir_durably_if_present(
            &self.storage,
            &self.directory,
            &stage_root,
            "cannot remove empty fork staging dir",
            "cannot sync empty fork staging directory removal",
        )?;
        remove_empty_fork_staging_root(&self.storage)
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
    storage: &CheckedStorage,
    session_id: &str,
    lifecycle: &mut SessionLifecycle,
    #[cfg(test)] mut stage_pause: Option<ForkStagePause>,
    #[cfg(not(test))] _stage_pause: Option<()>,
) -> Result<String, PocketError> {
    let loaded = load_session_transcript_at_storage(storage, session_id).await?;
    if loaded.messages.is_empty() {
        return Err(PocketError::Engine {
            message: format!("session {session_id} has no messages to fork"),
        });
    }

    let source_store = checked_index_store(storage)?;
    let source_needs_baseline = read_index_baseline(storage, session_id)?.is_none();
    let stored_model = read_session_model_record(storage, session_id)?;
    let model = match stored_model {
        Some(record) => record.model,
        None => indexed_session_model(storage, &source_store, session_id)?.ok_or_else(|| {
            PocketError::Engine {
                message: format!(
                    "cannot recover model for fork source {session_id}; resume it before forking"
                ),
            }
        })?,
    };
    write_session_model_record(storage, session_id, &model)?;
    if source_needs_baseline {
        save_index_session(
            storage,
            &source_store,
            session_id,
            Some(&derive_title(&loaded.messages)),
            &model,
            "cannot reconcile fork source session index",
        )?;
        reconcile_loaded_transcript(storage, &source_store, session_id, &loaded)?;
        write_index_baseline(storage, session_id)?;
    }
    let messages = loaded.messages;
    let fork_title = derive_title(&messages);

    let new_id = uuid::Uuid::new_v4().to_string();
    let key = session_key(storage.root(), &new_id);
    if matches!(
        lifecycle.sessions.get(&key),
        Some(SessionLifecycleState::Active { .. } | SessionLifecycleState::PendingFork)
    ) {
        return Err(PocketError::Engine {
            message: format!("generated fork session id collision: {new_id}"),
        });
    }
    if matches!(
        lifecycle.sessions.get(&key),
        Some(SessionLifecycleState::Tombstoned)
    ) {
        begin_session_deletion(storage, &new_id)?;
        cleanup_session_artifacts(storage, &new_id, SessionCleanupMarker::PendingDeletion)
            .map_err(|err| PocketError::Engine {
                message: format!("cannot clear deleted fork UUID collision: {err}"),
            })?;
        lifecycle.sessions.remove(&key);
    }

    let familiar_bytes = familiar_metadata_bytes_at_storage(storage, session_id)?;
    let mut stage = ForkStage::begin(storage, &new_id)?;
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
        stage
            .storage
            .validate_regular_file(&stage.transcript, true)
            .map_err(|err| {
                fork_stage_error("cannot preflight staged fork transcript", err, &mut stage)
            })?;
        if let Err(err) = write_transcript_entry(&stage.transcript, &entry).await {
            return Err(fork_stage_error(
                "cannot stage fork transcript",
                err,
                &mut stage,
            ));
        }
        stage
            .storage
            .validate_regular_file(&stage.transcript, false)
            .map_err(|err| {
                fork_stage_error("cannot validate staged fork transcript", err, &mut stage)
            })?;
        indexed_messages.push(PendingIndexRecord::from_message(
            &new_id,
            &uuid,
            message,
            &model,
            &fork_title,
        ));
        parent = Some(uuid);

        #[cfg(test)]
        if let Some(stage_pause) = stage_pause.take() {
            let _ = stage_pause.staged.send(());
            let _ = stage_pause.resume.await;
        }
    }

    stage
        .storage
        .validate_regular_file(&stage.transcript, false)
        .map_err(|err| {
            fork_stage_error(
                "cannot preflight staged fork transcript sync",
                err,
                &mut stage,
            )
        })?;
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

    let transcript_destination = storage
        .transcript_file(&new_id)
        .map_err(|err| fork_stage_error("cannot prepare fork transcript path", err, &mut stage))?;
    let transcript_directory = storage
        .transcripts_dir()
        .map_err(|err| fork_stage_error("cannot prepare transcript dir", err, &mut stage))?;
    ensure_durable_directory(
        storage,
        storage.root(),
        &transcript_directory,
        "cannot create transcript dir",
        "cannot sync transcript directory creation",
    )
    .map_err(|err| fork_stage_error("cannot prepare transcript dir", err, &mut stage))?;
    rename_checked_file(
        storage,
        &stage.transcript,
        &transcript_destination,
        "cannot publish fork transcript",
    )
    .map_err(|err| fork_stage_error("cannot publish fork transcript", err, &mut stage))?;
    stage.published_transcript = Some(transcript_destination);
    sync_directory(
        storage,
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
        let metadata_destination = storage.familiar_file(&new_id).map_err(|err| {
            fork_stage_error("cannot prepare fork metadata path", err, &mut stage)
        })?;
        let metadata_directory = storage
            .metadata_dir()
            .map_err(|err| fork_stage_error("cannot prepare metadata dir", err, &mut stage))?;
        ensure_durable_directory(
            storage,
            storage.root(),
            &metadata_directory,
            "cannot create metadata dir",
            "cannot sync metadata directory creation",
        )
        .map_err(|err| fork_stage_error("cannot prepare metadata dir", err, &mut stage))?;
        rename_checked_file(
            storage,
            &metadata,
            &metadata_destination,
            "cannot publish fork metadata",
        )
        .map_err(|err| fork_stage_error("cannot publish fork metadata", err, &mut stage))?;
        stage.metadata = None;
        stage.published_metadata = Some(metadata_destination);
        sync_directory(
            storage,
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

    if let Err(err) = preflight_session_artifacts(storage, &new_id) {
        return Err(fork_publication_error(
            "cannot preflight fork publication",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    if let Err(err) = write_session_model_record(storage, &new_id, &model) {
        return Err(fork_publication_error(
            "cannot publish fork model metadata",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    let store = match checked_index_store(storage) {
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
    if let Err(err) = storage.validate_sqlite_files() {
        return Err(fork_publication_error(
            "cannot preflight fork index",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    if let Err(err) = store.save_session(&new_id, Some(&fork_title), &model) {
        return Err(fork_publication_error(
            "cannot publish fork index",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    #[cfg(test)]
    if let Err(err) = fail_fork_publication_after_row_if_requested(storage) {
        return Err(fork_publication_error(
            "cannot publish fork index",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    for message in indexed_messages {
        if let Err(err) = save_index_message(
            storage,
            &store,
            &new_id,
            &message.message_uuid,
            &message.role,
            &message.text,
            "cannot publish fork message index",
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
    if let Err(err) = write_index_baseline(storage, &new_id) {
        return Err(fork_publication_error(
            "cannot publish fork index baseline",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
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
    lifecycle.sessions.insert(
        key,
        SessionLifecycleState::Active {
            generation: uuid::Uuid::new_v4(),
            writer: Weak::new(),
        },
    );
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
        let mut faults = SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let faults = faults.entry(root.to_path_buf()).or_default();
        faults.fail_fork_publication_after_row_once = fail_fork_publication_after_row_once;
        faults.fail_index_delete_remaining = fail_index_delete_remaining;
    }

    fn fail_session_index(root: &Path, count: usize) {
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(root.to_path_buf())
            .or_default()
            .fail_session_index_remaining = count;
    }

    fn fail_persist_before_first_intent(root: &Path, count: usize) {
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(root.to_path_buf())
            .or_default()
            .fail_persist_before_first_intent_remaining = count;
    }

    fn fail_message_index_attempts(root: &Path, failures: impl IntoIterator<Item = bool>) {
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(root.to_path_buf())
            .or_default()
            .fail_message_index_attempts = failures.into_iter().collect();
    }

    fn fail_transcript_append(root: &Path, count: usize) {
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(root.to_path_buf())
            .or_default()
            .fail_transcript_append_remaining = count;
    }

    fn fail_transcript_after_write(root: &Path, count: usize) {
        SESSION_TEST_FAULTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(root.to_path_buf())
            .or_default()
            .fail_transcript_after_write_remaining = count;
    }

    fn message_index_attempt_uuids(root: &Path, session_id: &str) -> Vec<String> {
        MESSAGE_INDEX_ATTEMPTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|attempt| attempt.root == root && attempt.session_id == session_id)
            .map(|attempt| attempt.uuid.clone())
            .collect()
    }

    fn message_index_attempts_for(root: &Path) -> Vec<MessageIndexAttempt> {
        MESSAGE_INDEX_ATTEMPTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|attempt| attempt.root == root)
            .cloned()
            .collect()
    }

    fn clear_message_index_attempts(root: &Path) {
        MESSAGE_INDEX_ATTEMPTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .retain(|attempt| attempt.root != root);
    }

    fn pending_index_dir(root: &Path) -> PathBuf {
        root.join(".session-lifecycle").join("pending-index")
    }

    fn pending_index_marker(root: &Path, session_id: &str) -> PathBuf {
        pending_index_dir(root).join(format!("{session_id}.json"))
    }

    fn pending_index_temporary(root: &Path, session_id: &str) -> PathBuf {
        pending_index_dir(root).join(format!(".{session_id}.json.tmp"))
    }

    fn session_model_marker(root: &Path, session_id: &str) -> PathBuf {
        root.join(".session-lifecycle")
            .join("session-models")
            .join(format!("{session_id}.json"))
    }

    fn index_baselines_dir(root: &Path) -> PathBuf {
        root.join(".session-lifecycle").join("index-baselines")
    }

    fn index_baseline_marker(root: &Path, session_id: &str) -> PathBuf {
        index_baselines_dir(root).join(format!("{session_id}.json"))
    }

    fn seed_index_baseline_record(root: &Path, session_id: &str) {
        let directory = index_baselines_dir(root);
        std::fs::create_dir_all(&directory).unwrap();
        let marker = index_baseline_marker(root, session_id);
        std::fs::write(
            &marker,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "session_id": session_id,
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::File::open(&marker).unwrap().sync_all().unwrap();
        std::fs::File::open(&directory).unwrap().sync_all().unwrap();
    }

    fn seed_pending_index_record(
        root: &Path,
        session_id: &str,
        message_uuid: &str,
        role: &str,
        text: &str,
    ) {
        let directory = pending_index_dir(root);
        std::fs::create_dir_all(&directory).unwrap();
        let bytes = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "session_id": session_id,
            "message_uuid": message_uuid,
            "role": role,
            "text": text,
            "model": "model",
            "title": "Pending",
        }))
        .unwrap();
        let marker = pending_index_marker(root, session_id);
        std::fs::write(&marker, bytes).unwrap();
        std::fs::File::open(&marker).unwrap().sync_all().unwrap();
        std::fs::File::open(&directory).unwrap().sync_all().unwrap();
    }

    fn seed_oversized_pending_index_record(root: &Path, session_id: &str) {
        let directory = pending_index_dir(root);
        std::fs::create_dir_all(&directory).unwrap();
        let marker = pending_index_marker(root, session_id);
        std::fs::File::create(&marker)
            .unwrap()
            .set_len(MAX_INDEX_RECORD_BYTES + 1)
            .unwrap();
        std::fs::File::open(&marker).unwrap().sync_all().unwrap();
        std::fs::File::open(&directory).unwrap().sync_all().unwrap();
    }

    fn seed_legacy_widened_band_pending_index_record(root: &Path, session_id: &str) {
        let record = PendingIndexRecord {
            version: INDEX_RECORD_VERSION,
            session_id: session_id.to_string(),
            message_uuid: uuid::Uuid::new_v4().to_string(),
            role: "user".to_string(),
            text: "\0".repeat(usize::try_from(MAX_TRANSCRIPT_BYTES / 6).unwrap()),
            model: "model".to_string(),
            title: "Speculative".to_string(),
        };
        let bytes = serde_json::to_vec(&record).unwrap();
        assert!(bytes.len() as u64 > MAX_TRANSCRIPT_BYTES);
        assert!(bytes.len() as u64 <= MAX_INDEX_RECORD_BYTES);
        let directory = pending_index_dir(root);
        std::fs::create_dir_all(&directory).unwrap();
        let marker = pending_index_marker(root, session_id);
        std::fs::write(&marker, bytes).unwrap();
        std::fs::File::open(&marker).unwrap().sync_all().unwrap();
        std::fs::File::open(&directory).unwrap().sync_all().unwrap();
    }

    fn oversized_high_escaping_text() -> String {
        let pairs = usize::try_from(MAX_TRANSCRIPT_BYTES / 2).unwrap();
        "x\"".repeat(pairs)
    }

    fn seed_legacy_first_turn_ghost(
        root: &Path,
        session_id: &str,
        message_uuid: &str,
        transcript_bytes: &[u8],
    ) {
        index_store(root)
            .unwrap()
            .save_session(session_id, Some("Pending"), "model")
            .unwrap();
        let storage = CheckedStorage::from_root(root).unwrap();
        write_session_model_record(&storage, session_id, "model").unwrap();
        seed_index_baseline_record(root, session_id);
        save_familiar_metadata_at_root(root, session_id, Some(&familiar())).unwrap();
        seed_pending_index_record(root, session_id, message_uuid, "user", "never appended");
        let directory = root.join("transcripts");
        std::fs::create_dir_all(&directory).unwrap();
        let transcript = transcript_file(root, session_id);
        std::fs::write(&transcript, transcript_bytes).unwrap();
        std::fs::File::open(&transcript)
            .unwrap()
            .sync_all()
            .unwrap();
        std::fs::File::open(&directory).unwrap().sync_all().unwrap();
    }

    async fn seed_transcript(root: &Path, session_id: &str, messages: &[Message]) -> Vec<String> {
        let directory = root.join("transcripts");
        std::fs::create_dir_all(&directory).unwrap();
        let transcript = transcript_file(root, session_id);
        let mut parent = None;
        let mut uuids = Vec::with_capacity(messages.len());
        for message in messages {
            let message_uuid = uuid::Uuid::new_v4().to_string();
            let entry = build_entry(
                message.clone(),
                &message_uuid,
                parent.as_deref(),
                session_id,
            );
            write_transcript_entry(&transcript, &entry).await.unwrap();
            parent = Some(message_uuid.clone());
            uuids.push(message_uuid);
        }
        std::fs::File::open(&transcript)
            .unwrap()
            .sync_all()
            .unwrap();
        std::fs::File::open(&directory).unwrap().sync_all().unwrap();
        uuids
    }

    async fn seed_legacy_session(
        root: &Path,
        session_id: &str,
        messages: &[Message],
    ) -> Vec<String> {
        index_store(root)
            .unwrap()
            .save_session(session_id, Some("Legacy"), "model")
            .unwrap();
        seed_transcript(root, session_id, messages).await
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

    fn fail_file_remove(path: &Path, count: usize) {
        FILE_REMOVE_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(path.to_path_buf(), count);
    }

    fn fail_file_create(path: &Path, count: usize) {
        FILE_CREATE_FAILURES
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
        MESSAGE_INDEX_ATTEMPTS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .retain(|attempt| attempt.root != root);
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

    #[cfg(unix)]
    const EXTERNAL_SENTINEL: &[u8] = b"external-session-storage-sentinel";

    #[cfg(unix)]
    fn external_sentinel(label: &str) -> (PathBuf, PathBuf) {
        let directory = test_storage(label);
        let sentinel = directory.join("sentinel");
        std::fs::write(&sentinel, EXTERNAL_SENTINEL).unwrap();
        (directory, sentinel)
    }

    #[cfg(unix)]
    fn assert_external_sentinel(sentinel: &Path) {
        assert_eq!(std::fs::read(sentinel).unwrap(), EXTERNAL_SENTINEL);
    }

    #[cfg(unix)]
    fn assert_external_sentinel_only(directory: &Path, sentinel: &Path) {
        assert_external_sentinel(sentinel);
        let entries = std::fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();
        assert_eq!(
            entries,
            [sentinel.file_name().unwrap().to_os_string()],
            "storage artifacts were created in {}",
            directory.display()
        );
    }

    #[cfg(unix)]
    fn assert_unsafe_storage_path<T>(result: Result<T, PocketError>, path: &Path, reason: &str) {
        let err = match result {
            Ok(_) => panic!("unsafe storage path was accepted: {}", path.display()),
            Err(err) => err,
        };
        let message = err.to_string();
        assert!(
            message.contains("persistence error"),
            "expected persistence error, got: {message}"
        );
        assert!(
            message.contains(&path.display().to_string()),
            "error did not identify {}: {message}",
            path.display()
        );
        assert!(
            message.contains(reason),
            "error did not identify reason {reason:?}: {message}"
        );
    }

    #[cfg(unix)]
    fn remove_symlink_if_present(path: &Path) {
        match std::fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                std::fs::remove_file(path).unwrap();
            }
            Ok(_) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => panic!("cannot inspect test symlink {}: {err}", path.display()),
        }
    }

    #[cfg(unix)]
    async fn create_persisted_test_session(storage: &Path) -> String {
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence = SessionPersistence::create(
            &storage.display().to_string(),
            session_id.clone(),
            "model".to_string(),
            None,
        )
        .await
        .unwrap();
        persistence
            .persist_new(&[Message::user("stored session")])
            .await
            .unwrap();
        drop(persistence);
        session_id
    }

    async fn create_deletion_fixture(storage: &Path) -> (String, SessionPersistence, PathBuf) {
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence = SessionPersistence::create(
            &storage.display().to_string(),
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        persistence
            .persist_new(&[Message::user("sensitive conversation")])
            .await
            .unwrap();
        let stage = fork_staging_dir(storage, &session_id);
        std::fs::create_dir_all(&stage).unwrap();
        let staged_file = stage.join("stale");
        std::fs::write(&staged_file, b"staged sensitive data").unwrap();
        (session_id, persistence, staged_file)
    }

    fn index_contains(root: &Path, session_id: &str) -> bool {
        index_store(root)
            .unwrap()
            .list_sessions()
            .unwrap()
            .iter()
            .any(|row| row.id == session_id)
    }

    fn index_search_contains(root: &Path, query: &str, session_id: &str) -> bool {
        index_store(root)
            .unwrap()
            .search_sessions(query)
            .unwrap()
            .iter()
            .any(|row| row.id == session_id)
    }

    fn indexed_message_count(root: &Path, session_id: &str) -> u32 {
        index_store(root)
            .unwrap()
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|row| row.id == session_id)
            .map(|row| row.message_count)
            .unwrap_or_default()
    }

    fn indexed_session_fields(root: &Path, session_id: &str) -> Option<(String, String, u32)> {
        index_store(root)
            .unwrap()
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|row| row.id == session_id)
            .map(|row| (row.title.unwrap_or_default(), row.model, row.message_count))
    }

    fn remove_sqlite_cache(root: &Path) {
        for suffix in ["", "-wal", "-shm"] {
            let path = root.join(format!("index.sqlite{suffix}"));
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                Err(err) => panic!("cannot remove SQLite cache {}: {err}", path.display()),
            }
        }
    }

    fn assert_deletion_fixture_present(storage: &Path, session_id: &str, staged_file: &Path) {
        assert!(index_contains(storage, session_id));
        assert!(transcript_file(storage, session_id).exists());
        assert!(familiar_file(storage, session_id).exists());
        assert!(staged_file.exists());
    }

    fn assert_deletion_targets_absent(storage: &Path, session_id: &str) {
        assert!(!index_contains(storage, session_id));
        assert!(!transcript_file(storage, session_id).exists());
        assert!(!familiar_file(storage, session_id).exists());
        assert!(!fork_staging_dir(storage, session_id).exists());
        assert!(!pending_fork_marker(storage, session_id).exists());
        assert!(!pending_deletion_marker(storage, session_id).exists());
        assert!(!pending_index_marker(storage, session_id).exists());
        assert!(!session_model_marker(storage, session_id).exists());
        assert!(!index_baseline_marker(storage, session_id).exists());
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
        assert_eq!(title.chars().count(), MAX_SESSION_TITLE_CHARS);
        assert!(!title.contains('\n'));
        assert_eq!(derive_title(&[]), "");
    }

    #[test]
    fn pending_index_bound_covers_transcript_and_bounded_metadata() {
        assert_eq!(
            MAX_INDEX_RECORD_BYTES,
            MAX_TRANSCRIPT_BYTES + MAX_SESSION_MODEL_RECORD_BYTES + MAX_INDEX_RECORD_ENVELOPE_BYTES
        );

        let record = PendingIndexRecord {
            version: INDEX_RECORD_VERSION,
            session_id: uuid::Uuid::nil().to_string(),
            message_uuid: uuid::Uuid::nil().to_string(),
            role: "assistant".to_string(),
            text: String::new(),
            model: String::new(),
            title: "\0".repeat(MAX_SESSION_TITLE_CHARS),
        };
        assert!(
            serde_json::to_vec(&record).unwrap().len() as u64 <= MAX_INDEX_RECORD_ENVELOPE_BYTES,
            "fixed fields and a maximally escaped derived title must fit the envelope"
        );

        let message = Message::user("text with \0, quotes \" and a slash \\");
        let entry = build_entry(
            message.clone(),
            &record.message_uuid,
            None,
            &record.session_id,
        );
        let transcript_line_bytes = serde_json::to_vec(&entry).unwrap().len() as u64 + 1;
        let bounded_model = "\0".repeat(10_000);
        let model_record = SessionModelRecord {
            version: INDEX_RECORD_VERSION,
            session_id: record.session_id.clone(),
            model: bounded_model.clone(),
        };
        assert!(
            serde_json::to_vec(&model_record).unwrap().len() as u64
                <= MAX_SESSION_MODEL_RECORD_BYTES
        );
        let pending = PendingIndexRecord::from_message(
            &record.session_id,
            &record.message_uuid,
            &message,
            &bounded_model,
            &record.title,
        );
        assert!(
            serde_json::to_vec(&pending).unwrap().len() as u64
                <= transcript_line_bytes
                    + MAX_SESSION_MODEL_RECORD_BYTES
                    + MAX_INDEX_RECORD_ENVELOPE_BYTES
        );
    }

    #[test]
    fn pending_index_writer_rejects_oversized_serialization_before_write() {
        let storage = test_storage("persist-pending-index-writer-size-limit");
        let session_id = uuid::Uuid::new_v4().to_string();
        let checked = CheckedStorage::from_root(&storage).unwrap();
        let record = PendingIndexRecord {
            version: INDEX_RECORD_VERSION,
            session_id: session_id.clone(),
            message_uuid: uuid::Uuid::new_v4().to_string(),
            role: "user".to_string(),
            text: "\0".repeat(usize::try_from(MAX_INDEX_RECORD_BYTES / 6 + 1).unwrap()),
            model: "model".to_string(),
            title: "Oversized".to_string(),
        };
        assert!(serde_json::to_vec(&record).unwrap().len() as u64 > MAX_INDEX_RECORD_BYTES);

        let err = write_pending_index_record(&checked, &record).unwrap_err();

        assert!(err.to_string().contains("pending index record size limit"));
        assert!(!pending_index_dir(&storage).exists());
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_index_temporary(&storage, &session_id).exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    fn chain_uuid_and_parent(entry: &TranscriptEntry) -> (String, Option<String>) {
        match entry {
            TranscriptEntry::User(message) | TranscriptEntry::Assistant(message) => (
                message.uuid.clone().expect("chain entry must have a UUID"),
                message.parent_uuid.clone(),
            ),
            _ => panic!("expected a chain entry"),
        }
    }

    #[tokio::test]
    async fn message_index_retry_reuses_durable_transcript_uuid() {
        let storage = test_storage("persist-index-retry");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("hello")];
        fail_message_index_attempts(&storage, [true]);

        let err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(err.to_string().contains("cannot index message"));
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        let (durable_uuid, parent) = chain_uuid_and_parent(&entries[0]);
        assert!(parent.is_none());
        assert_eq!(indexed_message_count(&storage, &session_id), 0);

        persistence.persist_new(&messages).await.unwrap();

        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(
            chain_uuid_and_parent(&entries[0]),
            (durable_uuid.clone(), None)
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            [durable_uuid.clone(), durable_uuid]
        );

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn second_message_index_failure_retries_without_reappend() {
        let storage = test_storage("persist-second-index-retry");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("first"), Message::assistant("second")];
        fail_message_index_attempts(&storage, [false, true]);

        let err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(err.to_string().contains("cannot index message"));
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 2);
        let (first_uuid, first_parent) = chain_uuid_and_parent(&entries[0]);
        let (second_uuid, second_parent) = chain_uuid_and_parent(&entries[1]);
        assert!(first_parent.is_none());
        assert_eq!(second_parent.as_deref(), Some(first_uuid.as_str()));
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        persistence.persist_new(&messages).await.unwrap();

        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(
            chain_uuid_and_parent(&entries[0]),
            (first_uuid.clone(), None)
        );
        assert_eq!(
            chain_uuid_and_parent(&entries[1]),
            (second_uuid.clone(), Some(first_uuid.clone()))
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 2);
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            [first_uuid, second_uuid.clone(), second_uuid]
        );

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn unchanged_message_slice_drains_pending_index_work() {
        let storage = test_storage("persist-unchanged-index-retry");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("unchanged")];
        fail_message_index_attempts(&storage, [true]);

        persistence.persist_new(&messages).await.unwrap_err();
        persistence.persist_new(&messages).await.unwrap();

        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn repeated_message_index_failures_never_append_extra_lines() {
        let storage = test_storage("persist-repeated-index-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("retry me")];
        fail_message_index_attempts(&storage, [true, true, true]);

        for _ in 0..3 {
            let err = persistence.persist_new(&messages).await.unwrap_err();
            assert!(err.to_string().contains("cannot index message"));
            assert_eq!(
                load_transcript(&transcript_file(&storage, &session_id))
                    .await
                    .unwrap()
                    .len(),
                1
            );
            assert_eq!(indexed_message_count(&storage, &session_id), 0);
        }

        persistence.persist_new(&messages).await.unwrap();
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn session_index_failure_after_append_recovers_without_reappend() {
        let storage = test_storage("persist-session-index-recovery");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("not yet durable")];
        fail_session_index(&storage, 1);

        let err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(err.to_string().contains("cannot index session"));
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        let (durable_uuid, parent) = chain_uuid_and_parent(&entries[0]);
        assert!(parent.is_none());
        assert!(pending_index_marker(&storage, &session_id).is_file());
        assert!(!index_contains(&storage, &session_id));
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 1);
            assert_eq!(state.last_uuid.as_deref(), Some(durable_uuid.as_str()));
            assert_eq!(state.pending_index.len(), 1);
        }

        drop(persistence);
        clear_module_state_for_root(&storage).await;
        remove_sqlite_cache(&storage);
        clear_message_index_attempts(&storage);

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, session_id);
        assert_eq!(listed[0].message_count, 1);
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            [durable_uuid]
        );
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn crash_before_first_intent_never_publishes_session_row() {
        let storage = test_storage("persist-crash-before-first-intent");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        fail_persist_before_first_intent(&storage, 1);

        let err = persistence
            .persist_new(&[Message::user("not durable")])
            .await
            .unwrap_err();
        assert!(err
            .to_string()
            .contains("injected abort before first pending index intent"));
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());

        drop(persistence);
        clear_module_state_for_root(&storage).await;

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!index_contains(&storage, &session_id));
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn transcript_append_failure_does_not_advance_state() {
        let storage = test_storage("persist-transcript-append-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("append later")];
        fail_transcript_append(&storage, 1);

        let err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(err.to_string().contains("cannot write transcript"));
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 0);
            assert!(state.last_uuid.is_none());
            assert!(state.pending_index.is_empty());
        }

        persistence.persist_new(&messages).await.unwrap();
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn later_append_failure_preserves_existing_session_row() {
        let storage = test_storage("persist-later-append-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[Message::user("durable first")])
            .await
            .unwrap();
        fail_transcript_append(&storage, 1);

        let err = persistence
            .persist_new(&[
                Message::user("durable first"),
                Message::assistant("append later"),
            ])
            .await
            .unwrap_err();

        assert!(err.to_string().contains("cannot write transcript"));
        assert_eq!(
            indexed_session_fields(&storage, &session_id),
            Some(("durable first".to_string(), "model".to_string(), 1))
        );
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(!pending_index_marker(&storage, &session_id).exists());

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn post_write_transcript_failure_rolls_back_before_retry() {
        let storage = test_storage("persist-transcript-post-write-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("append atomically")];
        fail_transcript_after_write(&storage, 1);

        let err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(err
            .to_string()
            .contains("injected post-write transcript failure"));
        assert!(load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap()
            .is_empty());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 0);
            assert!(state.last_uuid.is_none());
            assert!(state.pending_index.is_empty());
        }

        persistence.persist_new(&messages).await.unwrap();
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn rollback_failure_recovers_complete_append_without_duplicate() {
        let storage = test_storage("persist-transcript-rollback-recovery");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("recover complete append")];
        let transcript = transcript_file(&storage, &session_id);
        fail_transcript_after_write(&storage, 1);
        fail_file_remove(&transcript, 1);

        persistence.persist_new(&messages).await.unwrap();
        persistence.persist_new(&messages).await.unwrap();

        let entries = load_transcript(&transcript).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        let state = persistence.state.lock().await;
        assert_eq!(state.persisted, 1);
        assert!(state.pending_index.is_empty());
        drop(state);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn uncertain_append_failure_blocks_new_uuid_retry() {
        let storage = test_storage("persist-transcript-uncertain-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("do not duplicate uncertain append")];
        let transcript_directory = storage.join("transcripts");
        std::fs::create_dir_all(&transcript_directory).unwrap();
        let transcript = transcript_file(&storage, &session_id);
        fail_transcript_after_write(&storage, 1);
        fail_file_remove(&transcript, 2);
        fail_directory_sync(&transcript_directory, 1);

        let first_err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(first_err
            .to_string()
            .contains("append rollback failed twice"));
        let second_err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(second_err
            .to_string()
            .contains("append outcome remains uncertain"));

        let entries = load_transcript(&transcript).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(indexed_message_count(&storage, &session_id), 0);

        drop(persistence);
        clear_module_state_for_root(&storage).await;
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].message_count, 1);
        assert_eq!(load_transcript(&transcript).await.unwrap().len(), 1);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn restart_truncates_partial_tail_before_later_append() {
        let storage = test_storage("persist-transcript-partial-tail");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[Message::user("before partial tail")])
            .await
            .unwrap();
        let transcript = transcript_file(&storage, &session_id);
        let entries = load_transcript(&transcript).await.unwrap();
        let (first_uuid, _) = chain_uuid_and_parent(&entries[0]);
        drop(persistence);
        clear_module_state_for_root(&storage).await;

        std::fs::OpenOptions::new()
            .append(true)
            .open(&transcript)
            .unwrap()
            .write_all(br#"{"type":"assistant","uuid":"partial"#)
            .unwrap();

        let (resumed, mut messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        messages.push(Message::assistant("after partial tail"));
        resumed.persist_new(&messages).await.unwrap();

        let entries = load_transcript(&transcript).await.unwrap();
        assert_eq!(entries.len(), 2);
        let (_, parent) = chain_uuid_and_parent(&entries[1]);
        assert_eq!(parent.as_deref(), Some(first_uuid.as_str()));
        assert_eq!(indexed_message_count(&storage, &session_id), 2);

        drop(resumed);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn restart_preserves_complete_final_entry_without_newline() {
        let storage = test_storage("persist-transcript-missing-newline");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[Message::user("complete without newline")])
            .await
            .unwrap();
        let transcript = transcript_file(&storage, &session_id);
        let original_len = std::fs::metadata(&transcript).unwrap().len();
        std::fs::OpenOptions::new()
            .write(true)
            .open(&transcript)
            .unwrap()
            .set_len(original_len - 1)
            .unwrap();
        drop(persistence);
        clear_module_state_for_root(&storage).await;

        let (resumed, mut messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 1);
        messages.push(Message::assistant("after repaired newline"));
        resumed.persist_new(&messages).await.unwrap();

        let bytes = std::fs::read(&transcript).unwrap();
        assert_eq!(bytes.last(), Some(&b'\n'));
        assert_eq!(load_transcript(&transcript).await.unwrap().len(), 2);
        assert_eq!(indexed_message_count(&storage, &session_id), 2);

        drop(resumed);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[test]
    fn tail_repair_rejects_oversized_transcript_before_allocation() {
        let storage = test_storage("persist-transcript-oversized-tail");
        let session_id = uuid::Uuid::new_v4().to_string();
        let transcript_directory = storage.join("transcripts");
        std::fs::create_dir_all(&transcript_directory).unwrap();
        let transcript = transcript_file(&storage, &session_id);
        std::fs::File::create(&transcript)
            .unwrap()
            .set_len(claurst_core::session_storage::MAX_TRANSCRIPT_BYTES + 1)
            .unwrap();
        let checked = CheckedStorage::from_root(&storage).unwrap();

        let err = repair_incomplete_transcript_tail(&checked, &transcript).unwrap_err();
        assert!(err.to_string().contains("too large"));
        assert_eq!(
            std::fs::metadata(&transcript).unwrap().len(),
            claurst_core::session_storage::MAX_TRANSCRIPT_BYTES + 1
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[test]
    fn tail_repair_preserves_complete_future_json_entry() {
        let storage = test_storage("persist-transcript-future-tail");
        let session_id = uuid::Uuid::new_v4().to_string();
        let transcript_directory = storage.join("transcripts");
        std::fs::create_dir_all(&transcript_directory).unwrap();
        let transcript = transcript_file(&storage, &session_id);
        let future_entry = br#"{"type":"user","futureRequiredField":true}"#;
        std::fs::write(&transcript, future_entry).unwrap();
        let checked = CheckedStorage::from_root(&storage).unwrap();

        repair_incomplete_transcript_tail(&checked, &transcript).unwrap();

        let mut expected = future_entry.to_vec();
        expected.push(b'\n');
        assert_eq!(std::fs::read(&transcript).unwrap(), expected);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn transcript_size_limit_is_an_explicit_non_mutating_failure() {
        let storage = test_storage("persist-transcript-size-limit");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let transcript_directory = storage.join("transcripts");
        std::fs::create_dir_all(&transcript_directory).unwrap();
        let transcript = transcript_file(&storage, &session_id);
        std::fs::File::create(&transcript)
            .unwrap()
            .set_len(claurst_core::session_storage::MAX_TRANSCRIPT_BYTES)
            .unwrap();

        let err = persistence
            .persist_new(&[Message::user("must not be indexed")])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("transcript size limit"));
        assert_eq!(
            std::fs::metadata(&transcript).unwrap().len(),
            claurst_core::session_storage::MAX_TRANSCRIPT_BYTES
        );
        assert!(!index_contains(&storage, &session_id));
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 0);
            assert!(state.last_uuid.is_none());
            assert!(state.pending_index.is_empty());
        }

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn oversized_first_message_is_rejected_before_pending_intent() {
        let storage = test_storage("persist-oversized-first-message");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();

        let err = persistence
            .persist_new(&[Message::user(oversized_high_escaping_text())])
            .await
            .unwrap_err();

        assert!(err.to_string().contains("transcript size limit"));
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_index_temporary(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 0);
            assert!(state.last_uuid.is_none());
            assert!(state.pending_index.is_empty());
        }
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn oversized_later_message_preserves_existing_session() {
        let storage = test_storage("persist-oversized-later-message");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let first = Message::user("durable first message");
        persistence
            .persist_new(std::slice::from_ref(&first))
            .await
            .unwrap();
        let transcript = transcript_file(&storage, &session_id);
        let transcript_before = std::fs::read(&transcript).unwrap();
        let index_before = indexed_session_fields(&storage, &session_id).unwrap();
        let baseline_before = std::fs::read(index_baseline_marker(&storage, &session_id)).unwrap();

        let err = persistence
            .persist_new(&[first, Message::assistant(oversized_high_escaping_text())])
            .await
            .unwrap_err();

        assert!(err.to_string().contains("transcript size limit"));
        assert_eq!(std::fs::read(&transcript).unwrap(), transcript_before);
        assert_eq!(
            indexed_session_fields(&storage, &session_id),
            Some(index_before)
        );
        assert_eq!(
            std::fs::read(index_baseline_marker(&storage, &session_id)).unwrap(),
            baseline_before
        );
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_index_temporary(&storage, &session_id).exists());
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 1);
            assert!(state.pending_index.is_empty());
        }

        drop(persistence);
        clear_module_state_for_root(&storage).await;
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, session_id);
        assert_eq!(listed[0].message_count, 1);
        let (resumed, messages, _) =
            SessionPersistence::resume(&storage_str, session_id, "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 1);

        drop(resumed);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn new_transcript_directory_sync_failure_rolls_back_append() {
        let storage = test_storage("persist-transcript-file-sync-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let transcript_directory = storage.join("transcripts");
        std::fs::create_dir_all(&transcript_directory).unwrap();
        fail_directory_sync(&transcript_directory, 1);

        let err = persistence
            .persist_new(&[Message::user("durable creation")])
            .await
            .unwrap_err();
        assert!(err
            .to_string()
            .contains("cannot sync transcript file creation"));
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        {
            let state = persistence.state.lock().await;
            assert_eq!(state.persisted, 0);
            assert!(state.last_uuid.is_none());
            assert!(state.pending_index.is_empty());
        }

        persistence
            .persist_new(&[Message::user("durable creation")])
            .await
            .unwrap();
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn routine_operations_do_not_reindex_or_read_unrelated_transcripts() {
        let storage = test_storage("persist-routine-no-reconcile");
        let storage_str = storage.display().to_string();
        let unrelated_id = uuid::Uuid::new_v4().to_string();
        let unrelated = SessionPersistence::create(
            &storage_str,
            unrelated_id.clone(),
            "model".to_string(),
            None,
        )
        .await
        .unwrap();
        unrelated
            .persist_new(&[Message::user("already indexed")])
            .await
            .unwrap();
        drop(unrelated);
        let unrelated_transcript = transcript_file(&storage, &unrelated_id);
        std::fs::remove_file(&unrelated_transcript).unwrap();
        std::fs::create_dir(&unrelated_transcript).unwrap();
        clear_message_index_attempts(&storage);

        assert_eq!(list_sessions(&storage_str).await.unwrap().len(), 1);
        assert_eq!(list_sessions(&storage_str).await.unwrap().len(), 1);

        let unrelated_delete_id = uuid::Uuid::new_v4().to_string();
        let unrelated_delete = SessionPersistence::create(
            &storage_str,
            unrelated_delete_id.clone(),
            "model".to_string(),
            None,
        )
        .await
        .unwrap();
        drop(unrelated_delete);
        delete_session(&storage_str, &unrelated_delete_id)
            .await
            .unwrap();

        assert!(unrelated_transcript.is_dir());
        assert!(message_index_attempts_for(&storage).is_empty());
        assert_eq!(indexed_message_count(&storage, &unrelated_id), 1);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn one_pending_intent_among_one_hundred_sessions_indexes_only_its_uuid() {
        let storage = test_storage("persist-one-pending-of-one-hundred");
        let storage_str = storage.display().to_string();
        let mut sessions = Vec::new();
        for index in 0..100 {
            let session_id = uuid::Uuid::new_v4().to_string();
            let text = format!("session {index}");
            let uuids =
                seed_legacy_session(&storage, &session_id, &[Message::user(text.clone())]).await;
            sessions.push((session_id, uuids[0].clone(), text));
        }
        let (target_id, target_uuid, target_text) = sessions.last().unwrap().clone();
        seed_index_baseline_record(&storage, &target_id);
        seed_pending_index_record(&storage, &target_id, &target_uuid, "user", &target_text);
        clear_message_index_attempts(&storage);

        assert_eq!(list_sessions(&storage_str).await.unwrap().len(), 100);

        assert_eq!(
            message_index_attempts_for(&storage),
            [MessageIndexAttempt {
                root: storage.clone(),
                session_id: target_id.clone(),
                uuid: target_uuid,
            }]
        );
        assert_eq!(indexed_message_count(&storage, &target_id), 1);
        assert_eq!(indexed_message_count(&storage, &sessions[0].0), 0);
        assert!(!pending_index_marker(&storage, &target_id).exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn oversized_pending_marker_reindexes_only_affected_transcript() {
        let storage = test_storage("persist-oversized-one-of-one-hundred");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let target_store = index_store(&storage).unwrap();
        target_store
            .save_session(&session_id, Some("Stale"), "model")
            .unwrap();
        target_store
            .save_message(
                &session_id,
                &uuid::Uuid::new_v4().to_string(),
                "assistant",
                "stale index only",
                None,
            )
            .unwrap();
        let checked = CheckedStorage::from_root(&storage).unwrap();
        write_session_model_record(&checked, &session_id, "model").unwrap();
        seed_index_baseline_record(&storage, &session_id);
        let messages = [
            Message::user("actual first"),
            Message::assistant("actual second"),
        ];
        let actual_uuids = seed_transcript(&storage, &session_id, &messages).await;
        seed_oversized_pending_index_record(&storage, &session_id);

        let mut unrelated = Vec::new();
        for index in 0..100 {
            let session_id = uuid::Uuid::new_v4().to_string();
            let text = format!("unrelated {index}");
            let message_uuid = uuid::Uuid::new_v4().to_string();
            let store = index_store(&storage).unwrap();
            store
                .save_session(&session_id, Some(&text), "model")
                .unwrap();
            store
                .save_message(&session_id, &message_uuid, "user", &text, None)
                .unwrap();
            unrelated.push((session_id, text));
        }
        let unaffected_id = unrelated.last().unwrap().0.clone();
        let unaffected_before = indexed_session_fields(&storage, &unaffected_id).unwrap();
        clear_message_index_attempts(&storage);

        let listed = list_sessions(&storage_str).await.unwrap();

        assert!(listed.iter().any(|session| {
            session.session_id == session_id && session.message_count == messages.len() as u32
        }));
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            actual_uuids
        );
        assert_eq!(message_index_attempts_for(&storage).len(), messages.len());
        assert_eq!(
            indexed_message_count(&storage, &session_id),
            messages.len() as u32
        );
        assert_eq!(
            indexed_session_fields(&storage, &unaffected_id),
            Some(unaffected_before)
        );
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_index_temporary(&storage, &session_id).exists());
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        assert!(session_model_marker(&storage, &session_id).is_file());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn restart_recovers_durable_append_once_without_duplicate_line() {
        let storage = test_storage("persist-restart-pending-index");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("before restart")];
        fail_message_index_attempts(&storage, [true]);
        persistence.persist_new(&messages).await.unwrap_err();
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        let (durable_uuid, _) = chain_uuid_and_parent(&entries[0]);
        assert!(pending_index_marker(&storage, &session_id).is_file());
        drop(persistence);
        clear_module_state_for_root(&storage).await;

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].message_count, 1);
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        let recovery_attempts = message_index_attempt_uuids(&storage, &session_id);
        assert_eq!(recovery_attempts.len(), 1);
        assert_eq!(recovery_attempts[0], durable_uuid);
        assert!(!pending_index_marker(&storage, &session_id).exists());

        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);

        clear_message_index_attempts(&storage);
        let (resumed, mut messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        messages.push(Message::assistant("after recovery"));
        resumed.persist_new(&messages).await.unwrap();
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 2);
        let (_, parent) = chain_uuid_and_parent(&entries[1]);
        assert_eq!(parent.as_deref(), Some(durable_uuid.as_str()));
        assert_eq!(indexed_message_count(&storage, &session_id), 2);

        drop(resumed);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn recovery_removes_intent_when_append_never_happened() {
        let storage = test_storage("persist-intent-before-append");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let message_uuid = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Pending"), "model")
            .unwrap();
        seed_index_baseline_record(&storage, &session_id);
        seed_pending_index_record(
            &storage,
            &session_id,
            &message_uuid,
            "user",
            "never appended",
        );
        clear_message_index_attempts(&storage);

        let listed = list_sessions(&storage_str).await.unwrap();
        assert!(listed.is_empty());
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn oversized_pending_marker_deletes_absent_zero_count_ghost() {
        let storage = test_storage("persist-oversized-absent-first-turn-ghost");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Speculative"), "model")
            .unwrap();
        let checked = CheckedStorage::from_root(&storage).unwrap();
        write_session_model_record(&checked, &session_id, "model").unwrap();
        seed_index_baseline_record(&storage, &session_id);
        save_familiar_metadata_at_root(&storage, &session_id, Some(&familiar())).unwrap();
        seed_oversized_pending_index_record(&storage, &session_id);
        for index in 0..100 {
            index_store(&storage)
                .unwrap()
                .save_session(
                    &uuid::Uuid::new_v4().to_string(),
                    Some(&format!("unrelated {index}")),
                    "model",
                )
                .unwrap();
        }
        assert!(index_search_contains(&storage, "Speculative", &session_id));

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 100);
        assert!(listed
            .iter()
            .all(|session| session.session_id != session_id));
        assert!(!index_search_contains(&storage, "Speculative", &session_id));
        assert_deletion_targets_absent(&storage, &session_id);

        clear_module_state_for_root(&storage).await;
        assert_eq!(list_sessions(&storage_str).await.unwrap().len(), 100);
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn legacy_widened_band_marker_deletes_old_zero_count_ghost() {
        let storage = test_storage("persist-legacy-widened-band-first-turn-ghost");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Speculative widened band"), "model")
            .unwrap();
        let checked = CheckedStorage::from_root(&storage).unwrap();
        write_session_model_record(&checked, &session_id, "model").unwrap();
        seed_index_baseline_record(&storage, &session_id);
        seed_legacy_widened_band_pending_index_record(&storage, &session_id);
        for index in 0..100 {
            index_store(&storage)
                .unwrap()
                .save_session(
                    &uuid::Uuid::new_v4().to_string(),
                    Some(&format!("newer unrelated {index}")),
                    "model",
                )
                .unwrap();
        }
        assert!(index_search_contains(
            &storage,
            "Speculative widened band",
            &session_id
        ));

        assert_eq!(list_sessions(&storage_str).await.unwrap().len(), 100);

        assert!(!index_search_contains(
            &storage,
            "Speculative widened band",
            &session_id
        ));
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_deletion_marker(&storage, &session_id).exists());
        assert!(!session_model_marker(&storage, &session_id).exists());
        assert!(!index_baseline_marker(&storage, &session_id).exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn recovery_deletes_legacy_first_turn_ghost_with_empty_transcript() {
        let storage = test_storage("persist-legacy-empty-first-turn-ghost");
        let storage_str = storage.display().to_string();
        let unrelated_id = uuid::Uuid::new_v4().to_string();
        let unrelated = SessionPersistence::create(
            &storage_str,
            unrelated_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        unrelated
            .persist_new(&[Message::user("unrelated survives")])
            .await
            .unwrap();
        drop(unrelated);
        let unrelated_fields = indexed_session_fields(&storage, &unrelated_id).unwrap();
        let unrelated_transcript = std::fs::read(transcript_file(&storage, &unrelated_id)).unwrap();
        let unrelated_sidecar = std::fs::read(familiar_file(&storage, &unrelated_id)).unwrap();

        let session_id = uuid::Uuid::new_v4().to_string();
        seed_legacy_first_turn_ghost(
            &storage,
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            b"",
        );

        let listed = list_sessions(&storage_str).await.unwrap();

        assert_eq!(
            listed
                .iter()
                .map(|session| session.session_id.as_str())
                .collect::<Vec<_>>(),
            [unrelated_id.as_str()]
        );
        assert_deletion_targets_absent(&storage, &session_id);
        assert_eq!(
            indexed_session_fields(&storage, &unrelated_id),
            Some(unrelated_fields)
        );
        assert_eq!(
            std::fs::read(transcript_file(&storage, &unrelated_id)).unwrap(),
            unrelated_transcript
        );
        assert_eq!(
            std::fs::read(familiar_file(&storage, &unrelated_id)).unwrap(),
            unrelated_sidecar
        );

        clear_module_state_for_root(&storage).await;
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, unrelated_id);
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn recovery_deletes_legacy_first_turn_ghost_after_partial_tail_repair() {
        let storage = test_storage("persist-legacy-partial-first-turn-ghost");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        seed_legacy_first_turn_ghost(
            &storage,
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            br#"{"type":"user","uuid":"partial"#,
        );

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn legacy_first_turn_ghost_cleanup_retries_under_pending_deletion_marker() {
        let storage = test_storage("persist-legacy-first-turn-ghost-retry");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        seed_legacy_first_turn_ghost(
            &storage,
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            b"",
        );
        let transcript = transcript_file(&storage, &session_id);
        let external = storage.join("external-artifact");
        std::fs::write(&external, b"preserve me").unwrap();
        fail_file_remove(&transcript, 2);

        for _ in 0..2 {
            let err = match list_sessions(&storage_str).await {
                Ok(_) => panic!("incomplete ghost cleanup must fail recovery"),
                Err(err) => err,
            };
            assert!(err.to_string().contains("cannot delete transcript"));
            assert!(pending_deletion_marker(&storage, &session_id).is_file());
            assert!(!pending_index_marker(&storage, &session_id).exists());
            assert!(!index_baseline_marker(&storage, &session_id).exists());
            assert!(!session_model_marker(&storage, &session_id).exists());
            assert!(!familiar_file(&storage, &session_id).exists());
            assert!(!index_contains(&storage, &session_id));
            assert!(transcript.is_file());
            assert_eq!(std::fs::read(&external).unwrap(), b"preserve me");
            assert!(matches!(
                SESSION_LIFECYCLE_LOCK
                    .read()
                    .await
                    .sessions
                    .get(&session_key(&storage, &session_id)),
                Some(SessionLifecycleState::Tombstoned)
            ));
            clear_module_state_for_root(&storage).await;
        }

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);
        assert_eq!(std::fs::read(&external).unwrap(), b"preserve me");

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn absent_new_protocol_first_append_removes_only_pending_intent() {
        let storage = test_storage("persist-new-protocol-absent-first-append");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence = SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        .unwrap();
        let message = Message::user("never appended");
        let record = PendingIndexRecord::from_message(
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            &message,
            "model",
            "never appended",
        );
        write_pending_index_record(&persistence.storage, &record).unwrap();
        drop(persistence);
        clear_module_state_for_root(&storage).await;

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_deletion_marker(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        assert!(session_model_marker(&storage, &session_id).is_file());
        assert!(familiar_file(&storage, &session_id).is_file());

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!pending_deletion_marker(&storage, &session_id).exists());
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        assert!(session_model_marker(&storage, &session_id).is_file());
        assert!(familiar_file(&storage, &session_id).is_file());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn zero_count_row_with_nonempty_transcript_is_retained_for_reconciliation() {
        let storage = test_storage("persist-zero-count-nonempty-reconcile");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        seed_legacy_session(
            &storage,
            &session_id,
            &[Message::user("durable transcript")],
        )
        .await;
        save_familiar_metadata_at_root(&storage, &session_id, Some(&familiar())).unwrap();
        seed_pending_index_record(
            &storage,
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            "assistant",
            "missing later append",
        );

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, session_id);
        assert_eq!(listed[0].message_count, 0);
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!pending_deletion_marker(&storage, &session_id).exists());
        assert!(transcript_file(&storage, &session_id).is_file());
        assert!(familiar_file(&storage, &session_id).is_file());

        clear_module_state_for_root(&storage).await;
        let (resumed, messages, familiar) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 1);
        assert!(familiar.is_some());
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        drop(resumed);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn empty_indexed_session_without_pending_intent_is_not_deleted() {
        let storage = test_storage("persist-valid-empty-indexed-session");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Empty"), "model")
            .unwrap();
        seed_index_baseline_record(&storage, &session_id);
        save_familiar_metadata_at_root(&storage, &session_id, Some(&familiar())).unwrap();
        let transcript_directory = storage.join("transcripts");
        std::fs::create_dir_all(&transcript_directory).unwrap();
        std::fs::File::create(transcript_file(&storage, &session_id)).unwrap();

        let (persistence, messages, familiar) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert!(messages.is_empty());
        assert!(familiar.is_some());

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, session_id);
        assert_eq!(listed[0].message_count, 0);
        assert!(!pending_deletion_marker(&storage, &session_id).exists());
        assert!(transcript_file(&storage, &session_id).is_file());
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        assert!(familiar_file(&storage, &session_id).is_file());

        persistence
            .persist_new(&[Message::user("first valid append")])
            .await
            .unwrap();
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        drop(persistence);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn marker_removal_sync_failure_retries_idempotently() {
        let storage = test_storage("persist-marker-removal-retry");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let messages = vec![Message::user("index once")];
        fail_message_index_attempts(&storage, [true]);
        persistence.persist_new(&messages).await.unwrap_err();
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        let (durable_uuid, _) = chain_uuid_and_parent(&entries[0]);
        let pending_directory = pending_index_dir(&storage);
        fail_directory_sync(&pending_directory, 1);

        let err = persistence.persist_new(&messages).await.unwrap_err();
        assert!(err
            .to_string()
            .contains("cannot sync pending index marker removal"));
        assert!(pending_index_marker(&storage, &session_id).is_file());
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );

        persistence.persist_new(&messages).await.unwrap();

        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            [durable_uuid.clone(), durable_uuid.clone(), durable_uuid]
        );

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn repeated_recovery_index_failure_keeps_marker_and_ignores_unrelated_transcript() {
        let storage = test_storage("persist-recovery-index-retry");
        let storage_str = storage.display().to_string();
        let unrelated_id = uuid::Uuid::new_v4().to_string();
        let unrelated = SessionPersistence::create(
            &storage_str,
            unrelated_id.clone(),
            "model".to_string(),
            None,
        )
        .await
        .unwrap();
        unrelated
            .persist_new(&[Message::user("unrelated")])
            .await
            .unwrap();
        drop(unrelated);

        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        fail_message_index_attempts(&storage, [true]);
        persistence
            .persist_new(&[Message::user("recover only me")])
            .await
            .unwrap_err();
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        let (durable_uuid, _) = chain_uuid_and_parent(&entries[0]);
        drop(persistence);
        std::fs::write(
            transcript_file(&storage, &unrelated_id),
            b"unrelated malformed transcript\n",
        )
        .unwrap();
        clear_module_state_for_root(&storage).await;
        fail_message_index_attempts(&storage, [true, true]);

        for _ in 0..2 {
            let err = match list_sessions(&storage_str).await {
                Ok(_) => panic!("pending message index failure must be surfaced"),
                Err(err) => err,
            };
            assert!(err
                .to_string()
                .contains("cannot recover pending message index"));
            assert!(pending_index_marker(&storage, &session_id).is_file());
            assert_eq!(indexed_message_count(&storage, &session_id), 0);
            assert_eq!(
                load_transcript(&transcript_file(&storage, &session_id))
                    .await
                    .unwrap()
                    .len(),
                1
            );
        }
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            [durable_uuid.clone(), durable_uuid]
        );
        assert!(message_index_attempt_uuids(&storage, &unrelated_id).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn repeated_oversized_recovery_failure_keeps_marker_without_partial_mutation() {
        let storage = test_storage("persist-oversized-recovery-retry");
        let storage_str = storage.display().to_string();
        let unrelated_id = uuid::Uuid::new_v4().to_string();
        let unrelated = SessionPersistence::create(
            &storage_str,
            unrelated_id.clone(),
            "model".to_string(),
            None,
        )
        .await
        .unwrap();
        unrelated
            .persist_new(&[Message::user("unrelated")])
            .await
            .unwrap();
        drop(unrelated);
        let unrelated_before = indexed_session_fields(&storage, &unrelated_id).unwrap();

        let session_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Stale"), "model")
            .unwrap();
        let checked = CheckedStorage::from_root(&storage).unwrap();
        write_session_model_record(&checked, &session_id, "model").unwrap();
        seed_index_baseline_record(&storage, &session_id);
        let uuids = seed_transcript(
            &storage,
            &session_id,
            &[Message::user("retry oversized recovery")],
        )
        .await;
        seed_oversized_pending_index_record(&storage, &session_id);
        clear_message_index_attempts(&storage);
        fail_message_index_attempts(&storage, [true, true]);

        for _ in 0..2 {
            let err = match list_sessions(&storage_str).await {
                Ok(_) => panic!("oversized pending index recovery failure must be surfaced"),
                Err(err) => err,
            };
            assert!(err
                .to_string()
                .contains("cannot recover oversized pending message index"));
            assert!(pending_index_marker(&storage, &session_id).is_file());
            assert_eq!(indexed_message_count(&storage, &session_id), 0);
            assert_eq!(
                indexed_session_fields(&storage, &unrelated_id),
                Some(unrelated_before.clone())
            );
            assert_eq!(
                std::fs::metadata(pending_index_marker(&storage, &session_id))
                    .unwrap()
                    .len(),
                MAX_INDEX_RECORD_BYTES + 1
            );
        }
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            [uuids[0].clone(), uuids[0].clone()]
        );
        assert!(message_index_attempt_uuids(&storage, &unrelated_id).is_empty());

        assert!(list_sessions(&storage_str).await.is_ok());
        assert_eq!(indexed_message_count(&storage, &session_id), 1);
        assert!(!pending_index_marker(&storage, &session_id).exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn oversized_recovery_failure_precedes_normal_pending_mutation() {
        let storage = test_storage("persist-oversized-precedes-normal-recovery");
        let storage_str = storage.display().to_string();
        let normal_id = uuid::Uuid::new_v4().to_string();
        let normal_uuids =
            seed_legacy_session(&storage, &normal_id, &[Message::user("normal pending")]).await;
        seed_index_baseline_record(&storage, &normal_id);
        seed_pending_index_record(
            &storage,
            &normal_id,
            &normal_uuids[0],
            "user",
            "normal pending",
        );

        let oversized_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&oversized_id, Some("Oversized"), "model")
            .unwrap();
        seed_index_baseline_record(&storage, &oversized_id);
        seed_transcript(
            &storage,
            &oversized_id,
            &[Message::user("needs trusted model metadata")],
        )
        .await;
        seed_oversized_pending_index_record(&storage, &oversized_id);
        clear_message_index_attempts(&storage);

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("unsafe oversized recovery must fail"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("trusted model metadata"));
        assert!(pending_index_marker(&storage, &normal_id).is_file());
        assert!(pending_index_marker(&storage, &oversized_id).is_file());
        assert_eq!(indexed_message_count(&storage, &normal_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn malformed_pending_record_preflights_batch_before_index_mutation() {
        let storage = test_storage("persist-malformed-pending-index");
        let storage_str = storage.display().to_string();
        let valid_id = uuid::Uuid::new_v4().to_string();
        let valid_uuids =
            seed_legacy_session(&storage, &valid_id, &[Message::user("valid pending")]).await;
        seed_index_baseline_record(&storage, &valid_id);
        seed_pending_index_record(
            &storage,
            &valid_id,
            &valid_uuids[0],
            "user",
            "valid pending",
        );
        let malformed_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&malformed_id, Some("Malformed"), "model")
            .unwrap();
        std::fs::write(pending_index_marker(&storage, &malformed_id), b"{not-json").unwrap();
        clear_message_index_attempts(&storage);

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("malformed pending index record must fail recovery"),
            Err(err) => err,
        };
        assert!(err
            .to_string()
            .contains("cannot parse pending index record"));
        assert!(pending_index_marker(&storage, &valid_id).is_file());
        assert!(pending_index_marker(&storage, &malformed_id).is_file());
        assert_eq!(indexed_message_count(&storage, &valid_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn malformed_pending_record_uuid_preflights_before_index_mutation() {
        let storage = test_storage("persist-malformed-pending-index-uuid");
        let storage_str = storage.display().to_string();
        let valid_id = uuid::Uuid::new_v4().to_string();
        let valid_uuids =
            seed_legacy_session(&storage, &valid_id, &[Message::user("valid pending")]).await;
        seed_index_baseline_record(&storage, &valid_id);
        seed_pending_index_record(
            &storage,
            &valid_id,
            &valid_uuids[0],
            "user",
            "valid pending",
        );
        std::fs::File::create(pending_index_dir(&storage).join("not-a-uuid.json"))
            .unwrap()
            .set_len(MAX_INDEX_RECORD_BYTES + 1)
            .unwrap();
        clear_message_index_attempts(&storage);

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("malformed pending index UUID must fail recovery"),
            Err(err) => err,
        };
        assert!(err
            .to_string()
            .contains("invalid pending index record name"));
        assert!(pending_index_marker(&storage, &valid_id).is_file());
        assert_eq!(indexed_message_count(&storage, &valid_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn intent_publication_failure_happens_before_transcript_append() {
        let storage = test_storage("persist-intent-publication-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        fail_directory_sync(&pending_index_dir(&storage), 1);

        let err = persistence
            .persist_new(&[Message::user("must wait for durable intent")])
            .await
            .unwrap_err();

        assert!(err.to_string().contains("injected directory sync failure"));
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        let state = persistence.state.lock().await;
        assert_eq!(state.persisted, 0);
        assert!(state.pending_index.is_empty());
        drop(state);

        persistence
            .persist_new(&[Message::user("must wait for durable intent")])
            .await
            .unwrap();
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn external_recovery_of_absent_intent_does_not_wedge_live_writer() {
        let storage = test_storage("persist-live-writer-absent-intent");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        let message = Message::user("append after external recovery");
        let record = PendingIndexRecord::from_message(
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            &message,
            "model",
            "append after external recovery",
        );
        write_pending_index_record(&persistence.storage, &record).unwrap();
        persistence
            .state
            .lock()
            .await
            .pending_index
            .push_back(PendingIndexWork {
                record,
                appended: false,
            });

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!pending_index_marker(&storage, &session_id).exists());

        persistence.persist_new(&[message]).await.unwrap();

        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 1);

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_index_directory_symlink_fails_before_mutation() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-pending-index-directory");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        seed_legacy_session(&storage, &session_id, &[Message::user("preserve me")]).await;
        let lifecycle = storage.join(".session-lifecycle");
        std::fs::create_dir_all(&lifecycle).unwrap();
        let (external, sentinel) = external_sentinel("unsafe-pending-index-directory-target");
        let pending = pending_index_dir(&storage);
        symlink(&external, &pending).unwrap();
        clear_message_index_attempts(&storage);

        let result = list_sessions(&storage_str).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &pending, "symlink");
        remove_symlink_if_present(&pending);
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        assert!(transcript_file(&storage, &session_id).is_file());
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_index_record_symlink_preflights_batch_before_mutation() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-pending-index-record");
        let storage_str = storage.display().to_string();
        let valid_id = uuid::Uuid::new_v4().to_string();
        let valid_uuids =
            seed_legacy_session(&storage, &valid_id, &[Message::user("valid pending")]).await;
        seed_index_baseline_record(&storage, &valid_id);
        seed_pending_index_record(
            &storage,
            &valid_id,
            &valid_uuids[0],
            "user",
            "valid pending",
        );
        let unsafe_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&unsafe_id, Some("Unsafe"), "model")
            .unwrap();
        let (external, sentinel) = external_sentinel("unsafe-pending-index-record-target");
        let unsafe_marker = pending_index_marker(&storage, &unsafe_id);
        symlink(&sentinel, &unsafe_marker).unwrap();
        clear_message_index_attempts(&storage);

        let result = list_sessions(&storage_str).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &unsafe_marker, "symlink");
        assert_eq!(indexed_message_count(&storage, &valid_id), 0);
        assert!(pending_index_marker(&storage, &valid_id).is_file());
        assert!(message_index_attempts_for(&storage).is_empty());

        remove_symlink_if_present(&unsafe_marker);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn oversized_pending_index_symlink_preserves_sentinel_and_fails() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-oversized-pending-index-record");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&session_id, Some("Unsafe"), "model")
            .unwrap();
        let lifecycle = storage.join(".session-lifecycle");
        let pending = pending_index_dir(&storage);
        std::fs::create_dir_all(&pending).unwrap();
        let (external, sentinel) = external_sentinel("unsafe-oversized-pending-index-target");
        std::fs::File::options()
            .write(true)
            .open(&sentinel)
            .unwrap()
            .set_len(MAX_INDEX_RECORD_BYTES + 1)
            .unwrap();
        let mut sentinel_prefix_before = vec![0; EXTERNAL_SENTINEL.len()];
        std::fs::File::open(&sentinel)
            .unwrap()
            .read_exact(&mut sentinel_prefix_before)
            .unwrap();
        let marker = pending_index_marker(&storage, &session_id);
        symlink(&sentinel, &marker).unwrap();
        clear_message_index_attempts(&storage);

        let result = list_sessions(&storage_str).await;

        assert_eq!(
            std::fs::metadata(&sentinel).unwrap().len(),
            MAX_INDEX_RECORD_BYTES + 1
        );
        let mut sentinel_prefix_after = vec![0; EXTERNAL_SENTINEL.len()];
        std::fs::File::open(&sentinel)
            .unwrap()
            .read_exact(&mut sentinel_prefix_after)
            .unwrap();
        assert_eq!(sentinel_prefix_after, sentinel_prefix_before);
        assert_unsafe_storage_path(result, &marker, "symlink");
        assert!(marker.is_symlink());
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());
        assert!(lifecycle.is_dir());

        remove_symlink_if_present(&marker);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_removes_pending_index_without_resurrection() {
        let storage = test_storage("persist-delete-pending-index");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        fail_message_index_attempts(&storage, [true]);
        persistence
            .persist_new(&[Message::user("delete before recovery")])
            .await
            .unwrap_err();
        assert!(pending_index_marker(&storage, &session_id).is_file());
        drop(persistence);
        create_pending_deletion_marker_checked(
            &CheckedStorage::from_root(&storage).unwrap(),
            &session_id,
        )
        .unwrap();
        clear_module_state_for_root(&storage).await;

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!index_baseline_marker(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn direct_delete_supersedes_pending_index_before_recovery() {
        let storage = test_storage("persist-direct-delete-pending-index");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        fail_message_index_attempts(&storage, [true]);
        persistence
            .persist_new(&[Message::user("delete without replay")])
            .await
            .unwrap_err();
        assert!(pending_index_marker(&storage, &session_id).is_file());
        clear_message_index_attempts(&storage);

        delete_session(&storage_str, &session_id).await.unwrap();

        assert!(message_index_attempts_for(&storage).is_empty());
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!index_baseline_marker(&storage, &session_id).exists());
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));

        drop(persistence);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn legacy_resume_reconciles_once_then_uses_durable_baseline() {
        let storage = test_storage("persist-legacy-resume-baseline");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let uuids = seed_legacy_session(
            &storage,
            &session_id,
            &[Message::user("one"), Message::assistant("two")],
        )
        .await;
        clear_message_index_attempts(&storage);

        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].message_count, 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        let (first, messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(message_index_attempt_uuids(&storage, &session_id), uuids);
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        assert_eq!(indexed_message_count(&storage, &session_id), 2);
        drop(first);
        clear_message_index_attempts(&storage);

        let (second, messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 2);
        assert!(message_index_attempts_for(&storage).is_empty());
        assert_eq!(indexed_message_count(&storage, &session_id), 2);

        drop(second);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn legacy_fork_reconciles_source_once_and_baselines_destinations() {
        let storage = test_storage("persist-legacy-fork-baseline");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source_uuids = seed_legacy_session(
            &storage,
            &source_id,
            &[Message::user("one"), Message::assistant("two")],
        )
        .await;
        clear_message_index_attempts(&storage);

        let first_fork = fork_session(&storage_str, &source_id).await.unwrap();

        assert_eq!(
            message_index_attempt_uuids(&storage, &source_id),
            source_uuids
        );
        assert_eq!(message_index_attempt_uuids(&storage, &first_fork).len(), 2);
        assert!(index_baseline_marker(&storage, &source_id).is_file());
        assert!(index_baseline_marker(&storage, &first_fork).is_file());
        clear_message_index_attempts(&storage);

        let second_fork = fork_session(&storage_str, &source_id).await.unwrap();

        assert!(message_index_attempt_uuids(&storage, &source_id).is_empty());
        assert_eq!(message_index_attempt_uuids(&storage, &second_fork).len(), 2);
        assert!(index_baseline_marker(&storage, &second_fork).is_file());
        clear_message_index_attempts(&storage);

        let (resumed, messages, _) =
            SessionPersistence::resume(&storage_str, first_fork.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 2);
        assert!(message_index_attempts_for(&storage).is_empty());

        drop(resumed);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn new_sessions_and_fork_destinations_resume_without_full_reindex() {
        let storage = test_storage("persist-new-and-fork-baselines");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        persistence
            .persist_new(&[Message::user("one"), Message::assistant("two")])
            .await
            .unwrap();
        drop(persistence);
        clear_message_index_attempts(&storage);

        let (resumed, _, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert!(message_index_attempts_for(&storage).is_empty());
        drop(resumed);

        let fork_id = fork_session(&storage_str, &session_id).await.unwrap();
        assert!(index_baseline_marker(&storage, &fork_id).is_file());
        clear_message_index_attempts(&storage);
        let (forked, messages, _) =
            SessionPersistence::resume(&storage_str, fork_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 2);
        assert!(message_index_attempts_for(&storage).is_empty());
        assert_eq!(indexed_message_count(&storage, &fork_id), 2);

        drop(forked);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn direct_resume_rebuilds_recreated_index_once_and_preserves_chain() {
        let storage = test_storage("persist-recreated-index-baseline");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let persistence =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        persistence
            .persist_new(&[Message::user("one"), Message::assistant("two")])
            .await
            .unwrap();
        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        let transcript_uuids = entries
            .iter()
            .map(chain_uuid_and_parent)
            .map(|(message_uuid, _)| message_uuid)
            .collect::<Vec<_>>();
        let original_chain = entries
            .iter()
            .map(chain_uuid_and_parent)
            .collect::<Vec<_>>();
        drop(persistence);
        clear_module_state_for_root(&storage).await;
        remove_sqlite_cache(&storage);
        clear_message_index_attempts(&storage);

        let (resumed, messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(
            message_index_attempt_uuids(&storage, &session_id),
            transcript_uuids
        );
        assert_eq!(indexed_message_count(&storage, &session_id), 2);
        assert!(index_baseline_marker(&storage, &session_id).is_file());
        assert_eq!(
            load_transcript(&transcript_file(&storage, &session_id))
                .await
                .unwrap()
                .iter()
                .map(chain_uuid_and_parent)
                .collect::<Vec<_>>(),
            original_chain
        );

        drop(resumed);
        clear_message_index_attempts(&storage);
        let (resumed_again, messages, _) =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string())
                .await
                .unwrap();
        assert_eq!(messages.len(), 2);
        assert!(message_index_attempts_for(&storage).is_empty());
        assert_eq!(indexed_message_count(&storage, &session_id), 2);

        drop(resumed_again);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn direct_fork_rebuilds_source_after_index_recreation() {
        let storage = test_storage("fork-recreated-source-index");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source = SessionPersistence::create(
            &storage_str,
            source_id.clone(),
            "source-model".to_string(),
            None,
        )
        .await
        .unwrap();
        source
            .persist_new(&[
                Message::user("fork source title"),
                Message::assistant("source response"),
            ])
            .await
            .unwrap();
        let source_entries = load_transcript(&transcript_file(&storage, &source_id))
            .await
            .unwrap();
        let source_uuids = source_entries
            .iter()
            .map(chain_uuid_and_parent)
            .map(|(uuid, _)| uuid)
            .collect::<Vec<_>>();
        let source_chain = source_entries
            .iter()
            .map(chain_uuid_and_parent)
            .collect::<Vec<_>>();
        drop(source);
        clear_module_state_for_root(&storage).await;
        remove_sqlite_cache(&storage);
        clear_message_index_attempts(&storage);

        let fork_id = fork_session(&storage_str, &source_id).await.unwrap();

        assert_eq!(
            message_index_attempt_uuids(&storage, &source_id),
            source_uuids
        );
        assert_eq!(
            indexed_session_fields(&storage, &source_id),
            Some((
                "fork source title".to_string(),
                "source-model".to_string(),
                2
            ))
        );
        assert_eq!(
            indexed_session_fields(&storage, &fork_id),
            Some((
                "fork source title".to_string(),
                "source-model".to_string(),
                2
            ))
        );
        let fork_messages = load_session_messages_at_root(&storage, &fork_id)
            .await
            .unwrap()
            .0;
        assert_eq!(fork_messages.len(), 2);
        assert_eq!(fork_messages[0].get_all_text(), "fork source title");
        assert_eq!(fork_messages[1].get_all_text(), "source response");
        assert_eq!(
            load_transcript(&transcript_file(&storage, &source_id))
                .await
                .unwrap()
                .iter()
                .map(chain_uuid_and_parent)
                .collect::<Vec<_>>(),
            source_chain
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn recreated_index_fork_fails_closed_when_legacy_model_is_unrecoverable() {
        let storage = test_storage("fork-recreated-legacy-model");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        seed_legacy_session(&storage, &source_id, &[Message::user("legacy source")]).await;
        seed_index_baseline_record(&storage, &source_id);
        clear_module_state_for_root(&storage).await;
        remove_sqlite_cache(&storage);

        let err = fork_session(&storage_str, &source_id).await.unwrap_err();

        assert!(err
            .to_string()
            .contains("cannot recover model for fork source"));
        assert!(!session_model_marker(&storage, &source_id).exists());
        assert!(index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .is_empty());
        assert!(pending_fork_ids(&storage).unwrap().is_empty());
        assert_eq!(
            std::fs::read_dir(storage.join("transcripts"))
                .unwrap()
                .map(|entry| entry.unwrap().file_name())
                .collect::<Vec<_>>(),
            [std::ffi::OsString::from(format!("{source_id}.jsonl"))]
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_record_mismatch_fails_closed_and_retains_intent() {
        let storage = test_storage("persist-pending-index-mismatch");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let uuids =
            seed_legacy_session(&storage, &session_id, &[Message::user("transcript text")]).await;
        seed_index_baseline_record(&storage, &session_id);
        seed_pending_index_record(
            &storage,
            &session_id,
            &uuids[0],
            "user",
            "different marker text",
        );
        clear_message_index_attempts(&storage);

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("pending index mismatch must fail recovery"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("pending index record mismatch"));
        assert!(pending_index_marker(&storage, &session_id).is_file());
        assert_eq!(indexed_message_count(&storage, &session_id), 0);
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn absent_pending_record_for_unknown_session_is_removed_without_publication() {
        let storage = test_storage("persist-pending-index-unknown");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        seed_pending_index_record(
            &storage,
            &session_id,
            &uuid::Uuid::new_v4().to_string(),
            "user",
            "unknown",
        );

        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert!(!pending_index_marker(&storage, &session_id).exists());
        assert!(!index_contains(&storage, &session_id));
        assert!(message_index_attempts_for(&storage).is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn storage_root_symlink_is_rejected_without_touching_external_sentinel() {
        use std::os::unix::fs::symlink;

        let (external, sentinel) = external_sentinel("unsafe-root-target");
        let storage = test_storage("unsafe-root-link");
        std::fs::remove_dir(&storage).unwrap();
        symlink(&external, &storage).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &storage, "symlink");

        remove_symlink_if_present(&storage);
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn storage_root_symlink_with_trailing_separator_is_rejected_before_artifact_creation() {
        use std::os::unix::fs::symlink;

        let (external, sentinel) = external_sentinel("unsafe-root-slash-target");
        let storage = test_storage("unsafe-root-slash-link");
        std::fs::remove_dir(&storage).unwrap();
        symlink(&external, &storage).unwrap();
        let configured = format!("{}/", storage.display());

        let result = list_sessions(&configured).await;

        assert_external_sentinel_only(&external, &sentinel);
        assert_unsafe_storage_path(result, &storage, "symlink");

        remove_symlink_if_present(&storage);
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn storage_root_symlink_with_trailing_dot_is_rejected_before_artifact_creation() {
        use std::os::unix::fs::symlink;

        let (external, sentinel) = external_sentinel("unsafe-root-dot-target");
        let storage = test_storage("unsafe-root-dot-link");
        std::fs::remove_dir(&storage).unwrap();
        symlink(&external, &storage).unwrap();
        let configured = storage.join(".").display().to_string();

        let result = list_sessions(&configured).await;

        assert_external_sentinel_only(&external, &sentinel);
        assert_unsafe_storage_path(result, &storage, "symlink");

        remove_symlink_if_present(&storage);
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn storage_root_intermediate_symlink_to_missing_store_is_rejected_before_creation() {
        use std::os::unix::fs::symlink;

        let parent = test_storage("unsafe-intermediate-root-link");
        let alias = parent.join("alias");
        let (external, sentinel) = external_sentinel("unsafe-intermediate-root-target");
        symlink(&external, &alias).unwrap();
        let configured = alias.join("store");

        let result = list_sessions(&configured.display().to_string()).await;
        let sentinel_contents = std::fs::read(&sentinel).unwrap();
        let external_entries = std::fs::read_dir(&external)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();

        remove_symlink_if_present(&alias);
        std::fs::remove_dir_all(parent).unwrap();
        std::fs::remove_dir_all(external).unwrap();

        assert_eq!(sentinel_contents, EXTERNAL_SENTINEL);
        assert_eq!(
            external_entries,
            [sentinel.file_name().unwrap().to_os_string()],
            "storage root or index was created through {}",
            alias.display()
        );
        assert_unsafe_storage_path(result, &alias, "symlink");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn storage_root_intermediate_symlink_to_existing_store_is_rejected_before_artifacts() {
        use std::os::unix::fs::symlink;

        let parent = test_storage("unsafe-existing-intermediate-root-link");
        let alias = parent.join("alias");
        let external = test_storage("unsafe-existing-intermediate-root-target");
        let target_store = external.join("store");
        std::fs::create_dir(&target_store).unwrap();
        let sentinel = target_store.join("sentinel");
        std::fs::write(&sentinel, EXTERNAL_SENTINEL).unwrap();
        symlink(&external, &alias).unwrap();
        let configured = alias.join("store");

        let result = list_sessions(&configured.display().to_string()).await;
        let sentinel_contents = std::fs::read(&sentinel).unwrap();
        let store_entries = std::fs::read_dir(&target_store)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();

        remove_symlink_if_present(&alias);
        std::fs::remove_dir_all(parent).unwrap();
        std::fs::remove_dir_all(external).unwrap();

        assert_eq!(sentinel_contents, EXTERNAL_SENTINEL);
        assert_eq!(
            store_entries,
            [sentinel.file_name().unwrap().to_os_string()],
            "storage artifacts were created through {}",
            alias.display()
        );
        assert_unsafe_storage_path(result, &alias, "symlink");
    }

    #[tokio::test]
    async fn storage_root_missing_nested_components_are_created_and_usable() {
        let parent = test_storage("missing-nested-storage-root");
        let configured = parent.join("one").join("two").join("store");

        let sessions = list_sessions(&configured.display().to_string())
            .await
            .unwrap();

        assert!(sessions.is_empty());
        for directory in [
            parent.join("one"),
            parent.join("one").join("two"),
            configured.clone(),
        ] {
            let metadata = std::fs::symlink_metadata(&directory).unwrap();
            assert!(
                metadata.is_dir(),
                "{} was not a directory",
                directory.display()
            );
            assert!(
                !metadata.file_type().is_symlink(),
                "{} was a symlink",
                directory.display()
            );
        }
        assert!(configured.join("index.sqlite").is_file());

        std::fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn storage_root_parent_component_is_rejected() {
        let storage = test_storage("unsafe-root-parent");
        let child = storage.join("child");
        std::fs::create_dir(&child).unwrap();
        let configured = child.join("..");

        let err = CheckedStorage::open(&configured.display().to_string()).unwrap_err();
        let message = err.to_string();
        assert!(message.contains("persistence error"), "{message}");
        assert!(
            message.contains(&configured.display().to_string()),
            "{message}"
        );
        assert!(message.contains("parent"), "{message}");

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn metadata_symlink_is_rejected_by_session_start() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-metadata-start");
        let (external, sentinel) = external_sentinel("unsafe-metadata-start-target");
        let metadata = storage.join("metadata");
        symlink(&external, &metadata).unwrap();
        let session_id = uuid::Uuid::new_v4().to_string();

        let result = SessionPersistence::create(
            &storage.display().to_string(),
            session_id,
            "model".to_string(),
            Some(&familiar()),
        )
        .await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &metadata, "symlink");

        remove_symlink_if_present(&metadata);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn metadata_symlink_is_rejected_by_list_resume_and_delete() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-metadata-lifecycle");
        let storage_str = storage.display().to_string();
        let session_id = create_persisted_test_session(&storage).await;
        let (external, sentinel) = external_sentinel("unsafe-metadata-lifecycle-target");
        let metadata = storage.join("metadata");
        symlink(&external, &metadata).unwrap();

        let list_result = list_sessions(&storage_str).await;
        let resume_result =
            SessionPersistence::resume(&storage_str, session_id.clone(), "model".to_string()).await;
        let delete_result = delete_session(&storage_str, &session_id).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(list_result, &metadata, "symlink");
        assert_unsafe_storage_path(resume_result, &metadata, "symlink");
        assert_unsafe_storage_path(delete_result, &metadata, "symlink");

        remove_symlink_if_present(&metadata);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn transcripts_symlink_is_rejected_by_session_start() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-transcripts");
        let (external, sentinel) = external_sentinel("unsafe-transcripts-target");
        let transcripts = storage.join("transcripts");
        symlink(&external, &transcripts).unwrap();

        let result = SessionPersistence::create(
            &storage.display().to_string(),
            uuid::Uuid::new_v4().to_string(),
            "model".to_string(),
            None,
        )
        .await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &transcripts, "symlink");

        remove_symlink_if_present(&transcripts);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn lifecycle_symlink_is_rejected_during_recovery() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-lifecycle");
        let (external, sentinel) = external_sentinel("unsafe-lifecycle-target");
        let lifecycle = storage.join(".session-lifecycle");
        symlink(&external, &lifecycle).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &lifecycle, "symlink");

        remove_symlink_if_present(&lifecycle);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_forks_directory_symlink_is_rejected_during_recovery() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-pending-directory");
        let lifecycle = storage.join(".session-lifecycle");
        std::fs::create_dir(&lifecycle).unwrap();
        let (external, sentinel) = external_sentinel("unsafe-pending-directory-target");
        let pending = lifecycle.join("pending-forks");
        symlink(&external, &pending).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &pending, "symlink");

        remove_symlink_if_present(&pending);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn fork_staging_symlink_is_rejected_during_recovery() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-fork-staging");
        let (external, sentinel) = external_sentinel("unsafe-fork-staging-target");
        let staging = storage.join(".fork-staging");
        symlink(&external, &staging).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &staging, "symlink");

        remove_symlink_if_present(&staging);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn index_symlink_is_rejected_before_sqlite_touches_external_target() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-index");
        let (external, sentinel) = external_sentinel("unsafe-index-target");
        let index = storage.join("index.sqlite");
        symlink(&sentinel, &index).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &index, "symlink");

        remove_symlink_if_present(&index);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    async fn assert_sqlite_sidecar_symlink_is_rejected(suffix: &str) {
        use std::os::unix::fs::symlink;

        let storage = test_storage(&format!("unsafe-index-{suffix}"));
        let storage_str = storage.display().to_string();
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        let (external, sentinel) = external_sentinel(&format!("unsafe-index-{suffix}-target"));
        let sidecar = storage.join(format!("index.sqlite-{suffix}"));
        symlink(&sentinel, &sidecar).unwrap();

        let result = list_sessions(&storage_str).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &sidecar, "symlink");

        remove_symlink_if_present(&sidecar);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn index_wal_symlink_is_rejected_before_sqlite_open() {
        assert_sqlite_sidecar_symlink_is_rejected("wal").await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn index_shm_symlink_is_rejected_before_sqlite_open() {
        assert_sqlite_sidecar_symlink_is_rejected("shm").await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn familiar_sidecar_symlink_is_rejected_without_reading_external_target() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-familiar-leaf");
        let storage_str = storage.display().to_string();
        let session_id = create_persisted_test_session(&storage).await;
        let metadata = storage.join("metadata");
        std::fs::create_dir(&metadata).unwrap();
        let external = test_storage("unsafe-familiar-leaf-target");
        let sentinel = external.join("sentinel");
        let sentinel_bytes = serde_json::to_vec(&familiar()).unwrap();
        std::fs::write(&sentinel, &sentinel_bytes).unwrap();
        let sidecar = familiar_file(&storage, &session_id);
        symlink(&sentinel, &sidecar).unwrap();

        let result = list_sessions(&storage_str).await;

        assert_eq!(std::fs::read(&sentinel).unwrap(), sentinel_bytes);
        assert_unsafe_storage_path(result, &sidecar, "symlink");

        remove_symlink_if_present(&sidecar);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn transcript_leaf_symlink_is_rejected_without_reading_external_target() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-transcript-leaf");
        let storage_str = storage.display().to_string();
        let session_id = create_persisted_test_session(&storage).await;
        let transcript = transcript_file(&storage, &session_id);
        let external = test_storage("unsafe-transcript-leaf-target");
        let sentinel = external.join("sentinel.jsonl");
        std::fs::rename(&transcript, &sentinel).unwrap();
        let sentinel_bytes = std::fs::read(&sentinel).unwrap();
        symlink(&sentinel, &transcript).unwrap();

        let result =
            SessionPersistence::resume(&storage_str, session_id, "model".to_string()).await;

        assert_eq!(std::fs::read(&sentinel).unwrap(), sentinel_bytes);
        assert_unsafe_storage_path(result, &transcript, "symlink");

        remove_symlink_if_present(&transcript);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_fork_marker_symlink_is_rejected_during_recovery() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-pending-marker");
        let lifecycle = storage.join(".session-lifecycle");
        let pending = lifecycle.join("pending-forks");
        std::fs::create_dir_all(&pending).unwrap();
        let session_id = uuid::Uuid::new_v4().to_string();
        let (external, sentinel) = external_sentinel("unsafe-pending-marker-target");
        let marker = pending.join(format!("{session_id}.pending"));
        symlink(&sentinel, &marker).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &marker, "symlink");

        remove_symlink_if_present(&marker);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn staging_session_directory_symlink_is_rejected_during_recovery() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-stage-directory");
        let session_id = uuid::Uuid::new_v4().to_string();
        create_pending_fork_marker(&storage, &session_id).unwrap();
        let stage_root = storage.join(".fork-staging");
        std::fs::create_dir(&stage_root).unwrap();
        let (external, sentinel) = external_sentinel("unsafe-stage-directory-target");
        let stage = stage_root.join(&session_id);
        symlink(&external, &stage).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &stage, "symlink");

        remove_symlink_if_present(&stage);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn staged_transcript_symlink_is_rejected_during_recovery() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-staged-transcript");
        let session_id = uuid::Uuid::new_v4().to_string();
        create_pending_fork_marker(&storage, &session_id).unwrap();
        let stage = fork_staging_dir(&storage, &session_id);
        std::fs::create_dir_all(&stage).unwrap();
        let (external, sentinel) = external_sentinel("unsafe-staged-transcript-target");
        let staged_transcript = stage.join(format!("{session_id}.jsonl"));
        symlink(&sentinel, &staged_transcript).unwrap();

        let result = list_sessions(&storage.display().to_string()).await;

        assert_external_sentinel(&sentinel);
        assert_unsafe_storage_path(result, &staged_transcript, "symlink");

        remove_symlink_if_present(&staged_transcript);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn delete_preflight_failure_preserves_index_row_and_external_sentinel() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-delete-preflight");
        let storage_str = storage.display().to_string();
        let session_id = create_persisted_test_session(&storage).await;
        let transcript = transcript_file(&storage, &session_id);
        let external = test_storage("unsafe-delete-preflight-target");
        let sentinel = external.join("sentinel.jsonl");
        std::fs::rename(&transcript, &sentinel).unwrap();
        let sentinel_bytes = std::fs::read(&sentinel).unwrap();
        symlink(&sentinel, &transcript).unwrap();

        let result = delete_session(&storage_str, &session_id).await;

        assert_eq!(std::fs::read(&sentinel).unwrap(), sentinel_bytes);
        assert!(
            index_store(&storage)
                .unwrap()
                .list_sessions()
                .unwrap()
                .iter()
                .any(|row| row.id == session_id),
            "delete mutated the index before storage-path preflight completed"
        );
        assert_unsafe_storage_path(result, &transcript, "symlink");

        remove_symlink_if_present(&transcript);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn recovery_preflight_failure_preserves_rows_and_all_artifacts() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("unsafe-recovery-preflight");
        let storage_str = storage.display().to_string();
        let source_id = create_persisted_test_session(&storage).await;
        let destination_id = uuid::Uuid::new_v4().to_string();
        index_store(&storage)
            .unwrap()
            .save_session(&destination_id, Some("destination"), "model")
            .unwrap();
        std::fs::write(
            transcript_file(&storage, &destination_id),
            b"published destination transcript",
        )
        .unwrap();
        std::fs::create_dir_all(storage.join("metadata")).unwrap();
        std::fs::write(
            familiar_file(&storage, &destination_id),
            serde_json::to_vec(&familiar()).unwrap(),
        )
        .unwrap();
        create_pending_fork_marker(&storage, &destination_id).unwrap();
        let stage = fork_staging_dir(&storage, &destination_id);
        std::fs::create_dir_all(&stage).unwrap();
        let (external, sentinel) = external_sentinel("unsafe-recovery-preflight-target");
        let staged_transcript = stage.join(format!("{destination_id}.jsonl"));
        symlink(&sentinel, &staged_transcript).unwrap();
        clear_module_state_for_root(&storage).await;

        let result = list_sessions(&storage_str).await;

        assert_external_sentinel(&sentinel);
        let rows = index_store(&storage).unwrap().list_sessions().unwrap();
        assert!(rows.iter().any(|row| row.id == source_id));
        assert!(rows.iter().any(|row| row.id == destination_id));
        assert!(transcript_file(&storage, &destination_id).exists());
        assert!(familiar_file(&storage, &destination_id).exists());
        assert!(pending_fork_marker(&storage, &destination_id).exists());
        assert!(staged_transcript.exists());
        assert_unsafe_storage_path(result, &staged_transcript, "symlink");

        remove_symlink_if_present(&staged_transcript);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
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
            [
                storage.clone(),
                storage.join("metadata"),
                storage.clone(),
                storage.clone()
            ]
        );

        save_familiar_metadata_at_root(&storage, &session_id, Some(&familiar())).unwrap();
        assert_eq!(
            directory_syncs_for(&storage),
            [
                storage.clone(),
                storage.join("metadata"),
                storage.clone(),
                storage.clone(),
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
                storage.clone(),
                storage.clone(),
                storage.join("metadata"),
                storage.join("metadata")
            ]
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn create_rolls_back_sidecar_after_post_rename_directory_sync_failure() {
        let storage = test_storage("metadata-post-rename-sync");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let metadata_dir = storage.join("metadata");
        let destination = familiar_file(&storage, &session_id);
        fail_directory_sync(&metadata_dir, 1);

        let err = match SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        {
            Ok(_) => panic!("post-rename directory sync failure must fail create"),
            Err(err) => err,
        };

        assert!(err
            .to_string()
            .contains("cannot sync installed familiar metadata directory"));
        assert!(err.to_string().contains("injected directory sync failure"));
        assert!(!destination.exists());
        assert!(std::fs::read_dir(&metadata_dir).unwrap().next().is_none());
        assert!(!SESSION_LIFECYCLE_LOCK
            .read()
            .await
            .sessions
            .contains_key(&session_key(&storage, &session_id)));
        assert!(index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn create_reports_combined_error_when_sidecar_rollback_remove_fails() {
        let storage = test_storage("metadata-rollback-remove-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let metadata_dir = storage.join("metadata");
        let destination = familiar_file(&storage, &session_id);
        fail_directory_sync(&metadata_dir, 1);
        fail_file_remove(&destination, 1);

        let err = match SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        {
            Ok(_) => panic!("rollback removal failure must fail create"),
            Err(err) => err,
        };
        let message = err.to_string();

        assert!(message.contains("cannot sync installed familiar metadata directory"));
        assert!(message.contains("injected directory sync failure"));
        assert!(message.contains("rollback also failed"));
        assert!(message.contains("cannot roll back installed familiar metadata"));
        assert!(message.contains("injected file removal failure"));
        assert!(destination.exists());
        assert_eq!(
            std::fs::read_dir(&metadata_dir)
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
                .len(),
            1
        );
        assert!(!SESSION_LIFECYCLE_LOCK
            .read()
            .await
            .sessions
            .contains_key(&session_key(&storage, &session_id)));
        assert!(index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .is_empty());

        FILE_REMOVE_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&destination);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn create_reports_combined_error_when_sidecar_rollback_sync_fails() {
        let storage = test_storage("metadata-rollback-sync-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let metadata_dir = storage.join("metadata");
        let destination = familiar_file(&storage, &session_id);
        fail_directory_sync(&metadata_dir, 2);

        let err = match SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        {
            Ok(_) => panic!("rollback directory sync failure must fail create"),
            Err(err) => err,
        };
        let message = err.to_string();

        assert!(message.contains("cannot sync installed familiar metadata directory"));
        assert!(message.contains("rollback also failed"));
        assert!(message.contains("cannot sync familiar metadata rollback"));
        assert!(!destination.exists());
        assert!(std::fs::read_dir(&metadata_dir).unwrap().next().is_none());
        assert!(!SESSION_LIFECYCLE_LOCK
            .read()
            .await
            .sessions
            .contains_key(&session_key(&storage, &session_id)));
        assert!(index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn create_rename_failure_cleans_only_temporary_sidecar() {
        let storage = test_storage("metadata-rename-failure");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let metadata_dir = storage.join("metadata");
        let destination = familiar_file(&storage, &session_id);
        std::fs::create_dir_all(&destination).unwrap();

        let err = match SessionPersistence::create(
            &storage_str,
            session_id.clone(),
            "model".to_string(),
            Some(&familiar()),
        )
        .await
        {
            Ok(_) => panic!("rename over a directory must fail create"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("cannot install familiar metadata"));
        assert!(destination.is_dir());
        let entries = std::fs::read_dir(&metadata_dir)
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path(), destination);
        assert!(!SESSION_LIFECYCLE_LOCK
            .read()
            .await
            .sessions
            .contains_key(&session_key(&storage, &session_id)));
        assert!(index_store(&storage)
            .unwrap()
            .list_sessions()
            .unwrap()
            .is_empty());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[test]
    fn pending_marker_directory_sync_failure_removes_marker_durably() {
        let storage = test_storage("pending-marker-sync-failure");
        let session_id = uuid::Uuid::new_v4().to_string();
        let marker_directory = pending_forks_dir(&storage);
        fail_directory_sync(&marker_directory, 1);

        let err = create_pending_fork_marker(&storage, &session_id).unwrap_err();

        assert!(err
            .to_string()
            .contains("cannot sync pending fork marker directory"));
        assert!(err.to_string().contains("injected directory sync failure"));
        assert!(!pending_fork_marker(&storage, &session_id).exists());
        assert!(pending_fork_ids(&storage).unwrap().is_empty());
        assert_eq!(
            DIRECTORY_SYNC_EVENTS
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter()
                .filter(|path| path.as_path() == marker_directory)
                .count(),
            2
        );

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_recovers_transcript_remove_failure_after_index_delete() {
        let storage = test_storage("pending-deletion-transcript-remove");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let transcript = transcript_file(&storage, &session_id);
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_file_remove(&transcript, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err.to_string().contains("cannot delete transcript"));
        assert!(!index_contains(&storage, &session_id));
        assert!(transcript.exists());
        assert!(marker.exists());

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);
        assert!(matches!(
            SESSION_LIFECYCLE_LOCK
                .read()
                .await
                .sessions
                .get(&session_key(&storage, &session_id)),
            Some(SessionLifecycleState::Tombstoned)
        ));

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_recovers_transcript_directory_sync_failure() {
        let storage = test_storage("pending-deletion-transcript-sync");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let transcript_directory = storage.join("transcripts");
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_directory_sync(&transcript_directory, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err.to_string().contains("cannot sync transcript removal"));
        assert!(!index_contains(&storage, &session_id));
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(marker.exists());

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_recovers_sidecar_remove_failure() {
        let storage = test_storage("pending-deletion-sidecar-remove");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let sidecar = familiar_file(&storage, &session_id);
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_file_remove(&sidecar, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err.to_string().contains("cannot delete familiar metadata"));
        assert!(sidecar.exists());
        assert!(marker.exists());

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_recovers_fork_stage_cleanup_failure() {
        let storage = test_storage("pending-deletion-stage-remove");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, staged_file) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_file_remove(&staged_file, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err
            .to_string()
            .contains("cannot delete fork staging artifacts"));
        assert!(staged_file.exists());
        assert!(marker.exists());

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_marker_create_failure_preserves_session_and_artifacts() {
        let storage = test_storage("pending-deletion-marker-create");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, staged_file) = create_deletion_fixture(&storage).await;
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_file_create(&marker, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err
            .to_string()
            .contains("injected pending deletion marker creation failure"));
        assert!(!marker.exists());
        assert_deletion_fixture_present(&storage, &session_id, &staged_file);
        assert!(matches!(
            SESSION_LIFECYCLE_LOCK
                .read()
                .await
                .sessions
                .get(&session_key(&storage, &session_id)),
            Some(SessionLifecycleState::Active { .. })
        ));

        FILE_CREATE_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&marker);
        drop(persistence);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_marker_directory_sync_failure_preserves_session_and_artifacts() {
        let storage = test_storage("pending-deletion-marker-sync");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, staged_file) = create_deletion_fixture(&storage).await;
        let marker_directory = pending_deletions_dir(&storage);
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_directory_sync(&marker_directory, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err
            .to_string()
            .contains("cannot sync pending deletion marker directory"));
        assert!(!marker.exists());
        assert_deletion_fixture_present(&storage, &session_id, &staged_file);
        assert!(matches!(
            SESSION_LIFECYCLE_LOCK
                .read()
                .await
                .sessions
                .get(&session_key(&storage, &session_id)),
            Some(SessionLifecycleState::Active { .. })
        ));

        DIRECTORY_SYNC_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&marker_directory);
        drop(persistence);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_failed_marker_rollback_fences_writer_and_recovers() {
        let storage = test_storage("pending-deletion-marker-rollback");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, staged_file) = create_deletion_fixture(&storage).await;
        let marker_directory = pending_deletions_dir(&storage);
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_directory_sync(&marker_directory, 1);
        fail_file_remove(&marker, 1);

        let err = delete_session(&storage_str, &session_id).await.unwrap_err();

        assert!(err
            .to_string()
            .contains("cannot sync pending deletion marker directory"));
        assert!(err.to_string().contains("cleanup also failed"));
        assert!(err.to_string().contains("injected file removal failure"));
        assert!(marker.exists());
        assert_deletion_fixture_present(&storage, &session_id, &staged_file);

        let writer_err = persistence
            .persist_new(&[
                Message::user("sensitive conversation"),
                Message::assistant("stale append"),
            ])
            .await
            .unwrap_err();
        assert!(writer_err.to_string().contains("was deleted"));

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_deletion_directory_symlink_fails_closed_before_mutation() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("pending-deletion-directory-symlink");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, staged_file) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let (external, sentinel) = external_sentinel("pending-deletion-directory-target");
        let lifecycle = storage.join(".session-lifecycle");
        std::fs::create_dir_all(&lifecycle).unwrap();
        let directory = pending_deletions_dir(&storage);
        symlink(&external, &directory).unwrap();

        let result = delete_session(&storage_str, &session_id).await;
        assert_unsafe_storage_path(result, &directory, "symlink");
        assert_external_sentinel_only(&external, &sentinel);
        assert_external_sentinel_only(&external, &sentinel);
        remove_symlink_if_present(&directory);
        assert_deletion_fixture_present(&storage, &session_id, &staged_file);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_deletion_marker_symlink_fails_closed_before_mutation() {
        use std::os::unix::fs::symlink;

        let storage = test_storage("pending-deletion-marker-symlink");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, staged_file) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let (external, sentinel) = external_sentinel("pending-deletion-marker-target");
        let directory = pending_deletions_dir(&storage);
        std::fs::create_dir_all(&directory).unwrap();
        let marker = pending_deletion_marker(&storage, &session_id);
        symlink(&sentinel, &marker).unwrap();

        let result = delete_session(&storage_str, &session_id).await;

        assert_unsafe_storage_path(result, &marker, "symlink");
        assert_external_sentinel(&sentinel);
        assert_deletion_fixture_present(&storage, &session_id, &staged_file);

        remove_symlink_if_present(&marker);
        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(external).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_malformed_marker_preflights_entire_batch_before_mutation() {
        let storage = test_storage("pending-deletion-malformed-batch");
        let storage_str = storage.display().to_string();
        let (first_id, first, first_stage) = create_deletion_fixture(&storage).await;
        let (second_id, second, second_stage) = create_deletion_fixture(&storage).await;
        drop(first);
        drop(second);
        let directory = pending_deletions_dir(&storage);
        std::fs::create_dir_all(&directory).unwrap();
        let valid_marker = pending_deletion_marker(&storage, &first_id);
        std::fs::write(&valid_marker, b"").unwrap();
        let malformed_marker = directory.join("not-a-uuid.pending");
        std::fs::write(&malformed_marker, b"").unwrap();

        let err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("malformed pending-deletion marker must fail recovery"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("invalid pending deletion marker"));
        assert_deletion_fixture_present(&storage, &first_id, &first_stage);
        assert_deletion_fixture_present(&storage, &second_id, &second_stage);
        assert!(valid_marker.exists());
        assert!(malformed_marker.exists());

        clear_module_state_for_root(&storage).await;
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_repeated_recovery_failure_remains_retryable() {
        let storage = test_storage("pending-deletion-repeated-recovery");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let transcript = transcript_file(&storage, &session_id);
        let marker = pending_deletion_marker(&storage, &session_id);
        fail_file_remove(&transcript, 3);

        delete_session(&storage_str, &session_id).await.unwrap_err();
        assert!(marker.exists());
        assert!(transcript.exists());

        for _ in 0..2 {
            clear_module_state_for_root(&storage).await;
            let err = match list_sessions(&storage_str).await {
                Ok(_) => panic!("pending deletion recovery failure must fail list"),
                Err(err) => err,
            };
            assert!(err.to_string().contains("cannot recover pending deletion"));
            assert!(marker.exists());
            assert!(transcript.exists());
            assert!(!index_contains(&storage, &session_id));
        }

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
        assert_deletion_targets_absent(&storage, &session_id);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_success_removes_marker_last() {
        let storage = test_storage("pending-deletion-success");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        drop(persistence);

        delete_session(&storage_str, &session_id).await.unwrap();

        assert_deletion_targets_absent(&storage, &session_id);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_supersedes_pending_fork_recovery_for_same_destination() {
        let storage = test_storage("pending-deletion-supersedes-fork");
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
        let deletion_directory = pending_deletions_dir(&storage);
        std::fs::create_dir_all(&deletion_directory).unwrap();
        std::fs::write(pending_deletion_marker(&storage, &fork_id), b"").unwrap();
        assert!(pending_fork_marker(&storage, &fork_id).exists());

        clear_module_state_for_root(&storage).await;
        let listed = list_sessions(&storage_str).await.unwrap();

        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, source_id);
        assert_deletion_targets_absent(&storage, &fork_id);
        assert!(matches!(
            SESSION_LIFECYCLE_LOCK
                .read()
                .await
                .sessions
                .get(&session_key(&storage, &fork_id)),
            Some(SessionLifecycleState::Tombstoned)
        ));

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_retry_resyncs_unlinked_fork_marker_before_completion() {
        let storage = test_storage("pending-deletion-fork-marker-sync-retry");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        drop(persistence);
        let checked_storage = CheckedStorage::from_root(&storage).unwrap();
        create_pending_fork_marker_checked(&checked_storage, &session_id).unwrap();
        create_pending_deletion_marker_checked(&checked_storage, &session_id).unwrap();
        let fork_directory = pending_forks_dir(&storage);
        let fork_marker = pending_fork_marker(&storage, &session_id);
        let deletion_marker = pending_deletion_marker(&storage, &session_id);
        let fork_sync_count = || {
            DIRECTORY_SYNC_EVENTS
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter()
                .filter(|path| path.as_path() == fork_directory)
                .count()
        };

        clear_module_state_for_root(&storage).await;
        fail_directory_sync(&fork_directory, 1);
        let first_err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("pending-fork marker removal sync failure must fail recovery"),
            Err(err) => err,
        };

        assert!(first_err
            .to_string()
            .contains("cannot sync pending fork marker removal"));
        assert!(first_err
            .to_string()
            .contains("injected directory sync failure"));
        assert!(!fork_marker.exists());
        assert!(deletion_marker.exists());
        assert!(!index_contains(&storage, &session_id));
        assert!(!transcript_file(&storage, &session_id).exists());
        assert!(!familiar_file(&storage, &session_id).exists());
        assert!(!fork_staging_dir(&storage, &session_id).exists());
        let syncs_after_first_failure = fork_sync_count();

        clear_module_state_for_root(&storage).await;
        fail_directory_sync(&fork_directory, 1);
        let retry_err = match list_sessions(&storage_str).await {
            Ok(_) => panic!("absent pending-fork marker sync failure must fail recovery"),
            Err(err) => err,
        };

        assert!(retry_err
            .to_string()
            .contains("cannot sync absent pending fork marker"));
        assert!(retry_err
            .to_string()
            .contains("injected directory sync failure"));
        assert_eq!(fork_sync_count(), syncs_after_first_failure + 1);
        assert!(!fork_marker.exists());
        assert!(deletion_marker.exists());

        clear_module_state_for_root(&storage).await;
        let syncs_before_success = fork_sync_count();
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());

        assert_eq!(fork_sync_count(), syncs_before_success + 1);
        assert_deletion_targets_absent(&storage, &session_id);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn pending_deletion_fences_surviving_writer_before_failed_cleanup_returns() {
        let storage = test_storage("pending-deletion-writer-fence");
        let storage_str = storage.display().to_string();
        let (session_id, persistence, _) = create_deletion_fixture(&storage).await;
        let transcript = transcript_file(&storage, &session_id);
        fail_file_remove(&transcript, 1);

        delete_session(&storage_str, &session_id).await.unwrap_err();

        let err = persistence
            .persist_new(&[
                Message::user("sensitive conversation"),
                Message::assistant("stale append"),
            ])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("was deleted"));
        assert!(pending_deletion_marker(&storage, &session_id).exists());
        assert_eq!(
            load_session_messages_at_root(&storage, &session_id)
                .await
                .unwrap()
                .0
                .len(),
            1
        );

        clear_module_state_for_root(&storage).await;
        assert!(list_sessions(&storage_str).await.unwrap().is_empty());
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
        let storage_alias = storage.join(".").display().to_string();
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

        assert!(matches!(
            SESSION_LIFECYCLE_LOCK
                .read()
                .await
                .sessions
                .get(&session_key(&storage, &session_id)),
            Some(SessionLifecycleState::Tombstoned)
        ));
        drop(persistence);
        assert!(matches!(
            SESSION_LIFECYCLE_LOCK
                .read()
                .await
                .sessions
                .get(&session_key(&storage, &session_id)),
            Some(SessionLifecycleState::Tombstoned)
        ));

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
        let second_uuid = match &entries[1] {
            TranscriptEntry::Assistant(message) => {
                assert_eq!(message.session_id, fork_id);
                assert_eq!(message.parent_uuid.as_deref(), Some(first_uuid.as_str()));
                message.uuid.clone().unwrap()
            }
            _ => panic!("second fork entry must be the source assistant message"),
        };
        assert_ne!(first_uuid, second_uuid);
        assert_eq!(
            message_index_attempt_uuids(&storage, &fork_id),
            [first_uuid, second_uuid]
        );
        assert_eq!(indexed_message_count(&storage, &fork_id), 2);
        let fork_sidecar = storage
            .join("metadata")
            .join(format!("{fork_id}.familiar.json"));
        assert!(fork_sidecar.exists());

        delete_session(&storage_str, &fork_id).await.unwrap();
        assert!(!fork_sidecar.exists());

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn fork_destination_allows_one_writer_resume() {
        let storage = test_storage("fork-single-writer");
        let storage_str = storage.display().to_string();
        let source_id = uuid::Uuid::new_v4().to_string();
        let source =
            SessionPersistence::create(&storage_str, source_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        source
            .persist_new(&[
                Message::user("source message"),
                Message::assistant("source response"),
            ])
            .await
            .unwrap();

        let fork_id = fork_session(&storage_str, &source_id).await.unwrap();
        let (winner, _, _) =
            SessionPersistence::resume(&storage_str, fork_id.clone(), "model".to_string())
                .await
                .unwrap();
        let loser =
            match SessionPersistence::resume(&storage_str, fork_id.clone(), "model".to_string())
                .await
            {
                Ok(_) => panic!("a second fork writer resume must be rejected"),
                Err(err) => err,
            };

        assert!(loser
            .to_string()
            .contains(&format!("session {fork_id} is already open for writing")));
        drop(winner);
        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_resumes_grant_one_writer_and_preserve_linear_chain() {
        let storage = test_storage("resume-single-writer");
        let storage_str = storage.display().to_string();
        let session_id = uuid::Uuid::new_v4().to_string();
        let original =
            SessionPersistence::create(&storage_str, session_id.clone(), "model".to_string(), None)
                .await
                .unwrap();
        original
            .persist_new(&[
                Message::user("first message"),
                Message::assistant("first response"),
            ])
            .await
            .unwrap();
        drop(original);

        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(3));
        let first_barrier = barrier.clone();
        let first_storage = storage_str.clone();
        let first_id = session_id.clone();
        let first = tokio::spawn(async move {
            first_barrier.wait().await;
            SessionPersistence::resume(&first_storage, first_id, "model".to_string()).await
        });
        let second_barrier = barrier.clone();
        let second_storage = storage_str.clone();
        let second_id = session_id.clone();
        let second = tokio::spawn(async move {
            second_barrier.wait().await;
            SessionPersistence::resume(&second_storage, second_id, "model".to_string()).await
        });
        barrier.wait().await;

        let first = first.await.unwrap();
        let second = second.await.unwrap();
        let ((winner, mut messages, _), loser) = match (first, second) {
            (Ok(winner), Err(loser)) | (Err(loser), Ok(winner)) => (winner, loser),
            (Ok(_), Ok(_)) => panic!("both concurrent resumes claimed a writer"),
            (Err(first), Err(second)) => {
                panic!("both concurrent resumes failed: {first}; {second}")
            }
        };
        assert!(loser
            .to_string()
            .contains(&format!("session {session_id} is already open for writing")));

        messages.push(Message::user("winner follow-up"));
        winner.persist_new(&messages).await.unwrap();

        let entries = load_transcript(&transcript_file(&storage, &session_id))
            .await
            .unwrap();
        assert_eq!(entries.len(), 3);
        let first_uuid = match &entries[0] {
            TranscriptEntry::User(message) => {
                assert!(message.parent_uuid.is_none());
                message.uuid.as_deref().unwrap()
            }
            _ => panic!("first transcript entry must be a user message"),
        };
        let second_uuid = match &entries[1] {
            TranscriptEntry::Assistant(message) => {
                assert_eq!(message.parent_uuid.as_deref(), Some(first_uuid));
                message.uuid.as_deref().unwrap()
            }
            _ => panic!("second transcript entry must be an assistant message"),
        };
        match &entries[2] {
            TranscriptEntry::User(message) => {
                assert_eq!(message.parent_uuid.as_deref(), Some(second_uuid));
            }
            _ => panic!("third transcript entry must be a user message"),
        }
        let listed = list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].message_count, 3);

        drop(winner);
        std::fs::remove_dir_all(storage).unwrap();
    }

    async fn assert_fork_directory_sync_failure_rolls_back(
        label: &str,
        directory_name: &str,
        expected_context: &str,
    ) {
        let storage = test_storage(label);
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
        fail_directory_sync(&storage.join(directory_name), 1);

        let err = fork_session(&storage_str, &source_id).await.unwrap_err();

        assert!(err.to_string().contains(expected_context));
        assert!(err.to_string().contains("injected directory sync failure"));
        assert_eq!(
            index_store(&storage)
                .unwrap()
                .list_sessions()
                .unwrap()
                .len(),
            1
        );
        let transcript_names = std::fs::read_dir(storage.join("transcripts"))
            .unwrap()
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            transcript_names,
            [std::ffi::OsString::from(format!("{source_id}.jsonl"))]
        );
        let metadata_names = std::fs::read_dir(storage.join("metadata"))
            .unwrap()
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            metadata_names,
            [std::ffi::OsString::from(format!(
                "{source_id}.familiar.json"
            ))]
        );
        assert!(pending_fork_ids(&storage).unwrap().is_empty());
        assert!(!storage.join(".fork-staging").exists());
        let lifecycle = SESSION_LIFECYCLE_LOCK.read().await;
        assert_eq!(
            lifecycle
                .sessions
                .iter()
                .filter(|(key, _)| key.root == storage)
                .count(),
            1
        );
        assert!(matches!(
            lifecycle.sessions.get(&session_key(&storage, &source_id)),
            Some(SessionLifecycleState::Active { .. })
        ));
        drop(lifecycle);

        std::fs::remove_dir_all(storage).unwrap();
    }

    #[tokio::test]
    async fn fork_transcript_directory_sync_failure_rolls_back_published_destination() {
        assert_fork_directory_sync_failure_rolls_back(
            "fork-transcript-sync-rollback",
            "transcripts",
            "cannot make published fork transcript durable",
        )
        .await;
    }

    #[tokio::test]
    async fn fork_metadata_directory_sync_failure_rolls_back_published_destinations() {
        assert_fork_directory_sync_failure_rolls_back(
            "fork-metadata-sync-rollback",
            "metadata",
            "cannot make published fork metadata durable",
        )
        .await;
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
        let checked_storage = CheckedStorage::from_root(&storage).unwrap();
        let plan = preflight_pending_lifecycle_recovery(&checked_storage, &lifecycle).unwrap();
        recover_pending_lifecycle_plan(&checked_storage, &mut lifecycle, plan).unwrap();
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
        drop(persistence);

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
