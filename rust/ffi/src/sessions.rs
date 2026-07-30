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
use std::sync::{Arc, LazyLock, Weak};

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

#[cfg(test)]
static FILE_REMOVE_FAILURES: LazyLock<std::sync::Mutex<HashMap<PathBuf, usize>>> =
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
            let pending = self.pending_forks_dir()?;
            self.validate_directory(&pending, true)?;
        }
        self.validate_sqlite_files()
    }
}

fn checked_index_store(storage: &CheckedStorage) -> Result<SqliteSessionStore, PocketError> {
    storage.validate_sqlite_files()?;
    let index = storage.index_file("")?;
    storage.validate_regular_file(&index, true)?;
    SqliteSessionStore::open(&index).map_err(|err| engine_err("cannot open session index", err))
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
    session_id: &str,
) -> Result<String, PocketError> {
    let rows = checked_index_store(storage)?
        .list_sessions()
        .map_err(|err| engine_err("cannot list sessions", err))?;
    validate_indexed_session_ids(rows.iter().map(|row| row.id.as_str()))?;
    Ok(rows
        .into_iter()
        .find(|row| row.id == session_id)
        .map(|row| row.model)
        .unwrap_or_default())
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
    #[cfg(test)]
    let remove_result = {
        let mut failures = FILE_REMOVE_FAILURES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match failures.get_mut(path) {
            Some(remaining) if *remaining > 0 => {
                *remaining -= 1;
                Err(std::io::Error::other("injected file removal failure"))
            }
            _ => std::fs::remove_file(path),
        }
    };
    #[cfg(not(test))]
    let remove_result = std::fs::remove_file(path);

    match remove_result {
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
        std::fs::remove_file(&file).map_err(|err| engine_err(remove_context, err))?;
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
        recover_pending_forks_unlocked(&storage, &mut lifecycle)?;
        match lifecycle.sessions.get(&key) {
            Some(SessionLifecycleState::Active { .. }) => {
                return Err(PocketError::Engine {
                    message: format!("generated session id collision: {session_id}"),
                });
            }
            Some(SessionLifecycleState::Tombstoned) => {
                cleanup_session_artifacts(&storage, &session_id).map_err(|err| {
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
        save_familiar_metadata_at_storage(&storage, &session_id, familiar)?;
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
        recover_pending_forks_unlocked(&storage, &mut lifecycle)?;
        ensure_session_available(&lifecycle, &key)?;
        if matches!(
            lifecycle.sessions.get(&key),
            Some(SessionLifecycleState::Active { writer, .. }) if writer.upgrade().is_some()
        ) {
            return Err(PocketError::Engine {
                message: format!("session {session_id} is already open for writing"),
            });
        }
        let (messages, last_uuid) = load_session_messages_at_storage(&storage, &session_id).await?;
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
        let store = checked_index_store(&self.storage)?;
        self.storage.validate_sqlite_files()?;
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
            self.storage.validate_regular_file(&path, true)?;
            write_transcript_entry(&path, &entry)
                .await
                .map_err(|e| engine_err("cannot write transcript", e))?;
            self.storage.validate_regular_file(&path, false)?;
            self.storage.validate_sqlite_files()?;
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

async fn load_session_messages_at_storage(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(Vec<Message>, Option<String>), PocketError> {
    let path = storage.transcript_file(session_id)?;
    if !storage.validate_regular_file(&path, true)? {
        return Err(PocketError::Engine {
            message: format!("no stored session {session_id}"),
        });
    }
    storage.validate_regular_file(&path, false)?;
    let entries = load_transcript(&path)
        .await
        .map_err(|e| engine_err("cannot load transcript", e))?;
    let last_uuid = entries
        .iter()
        .rev()
        .find_map(|e| e.uuid().map(str::to_string));
    Ok((messages_from_transcript(&entries), last_uuid))
}

#[cfg(test)]
async fn load_session_messages_at_root(
    root: &Path,
    session_id: &str,
) -> Result<(Vec<Message>, Option<String>), PocketError> {
    load_session_messages_at_storage(&CheckedStorage::from_root(root)?, session_id).await
}

/// Newest-first summaries for the browser.
pub async fn list_sessions(storage_dir: &str) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let storage = CheckedStorage::open(storage_dir)?;
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_pending_forks_unlocked(&storage, &mut lifecycle)?;
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

/// Drop a session from the index and delete its transcript file.
pub async fn delete_session(storage_dir: &str, session_id: &str) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let storage = CheckedStorage::open(storage_dir)?;
    let key = session_key(storage.root(), session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    let in_memory_pending = matches!(
        lifecycle.sessions.get(&key),
        Some(SessionLifecycleState::PendingFork)
    );
    let mut is_pending = preflight_session_artifacts(&storage, session_id)?.marker_exists;
    if in_memory_pending && !is_pending {
        ensure_pending_fork_marker_checked(&storage, session_id)?;
        preflight_session_artifacts(&storage, session_id)?;
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
    match cleanup_session_artifacts(&storage, session_id) {
        Ok(()) => {
            lifecycle
                .sessions
                .insert(key, SessionLifecycleState::Tombstoned);
            Ok(())
        }
        Err(err) => Err(err),
    }
}

struct SessionArtifactPreflight {
    marker_exists: bool,
}

fn preflight_session_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<SessionArtifactPreflight, PocketError> {
    validate_session_id(session_id)?;
    storage.validate_fixed_layout()?;
    storage.validate_sqlite_files()?;
    storage.validate_regular_file(&storage.transcript_file(session_id)?, true)?;
    storage.validate_regular_file(&storage.familiar_file(session_id)?, true)?;
    let marker = storage.pending_fork_marker(session_id)?;
    let marker_exists = storage.validate_regular_file(&marker, true)?;
    let stage_directory = storage.fork_staging_dir(session_id)?;
    preflight_removal_tree(storage, &stage_directory)?;
    Ok(SessionArtifactPreflight { marker_exists })
}

fn cleanup_session_artifacts(
    storage: &CheckedStorage,
    session_id: &str,
) -> Result<(), PocketError> {
    let preflight = preflight_session_artifacts(storage, session_id)?;
    delete_index_session(storage, session_id, "cannot delete session index")?;

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
    if errors.is_empty() && preflight.marker_exists {
        if let Err(err) = remove_pending_fork_marker_checked(storage, session_id, true) {
            errors.push(err.to_string());
            if let Err(restore_err) = ensure_pending_fork_marker_checked(storage, session_id) {
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
    storage: &CheckedStorage,
    lifecycle: &mut SessionLifecycle,
) -> Result<(), PocketError> {
    let pending_ids = pending_fork_ids_checked(storage)?;
    preflight_fork_staging_entries(storage)?;
    for session_id in &pending_ids {
        preflight_session_artifacts(storage, session_id)?;
    }
    if let Some(key) = lifecycle.sessions.keys().find(|key| {
        key.root == storage.root()
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
        let key = session_key(storage.root(), session_id);
        lifecycle
            .sessions
            .insert(key.clone(), SessionLifecycleState::PendingFork);
        if let Err(err) = cleanup_session_artifacts(storage, session_id) {
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
    let storage = CheckedStorage::open(storage_dir)?;
    let key = session_key(storage.root(), session_id);
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    recover_pending_forks_unlocked(&storage, &mut lifecycle)?;
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
    recover_pending_forks_unlocked(&storage, &mut lifecycle)?;
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
        preflight_session_artifacts(&self.storage, &self.session_id)?;
        let mut errors = Vec::new();
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
    let (messages, _) = load_session_messages_at_storage(storage, session_id).await?;
    if messages.is_empty() {
        return Err(PocketError::Engine {
            message: format!("session {session_id} has no messages to fork"),
        });
    }

    // Model comes from the source's index row; the transcript doesn't carry it.
    let model = indexed_session_model(storage, session_id)?;

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
        cleanup_session_artifacts(storage, &new_id).map_err(|err| PocketError::Engine {
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
        indexed_messages.push((uuid.clone(), message));
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
    if let Err(err) = fail_fork_publication_after_row_if_requested(storage) {
        return Err(fork_publication_error(
            "cannot publish fork index",
            err,
            &mut stage,
            lifecycle,
            &key,
        ));
    }
    for (uuid, message) in indexed_messages {
        if let Err(err) = storage.validate_sqlite_files() {
            return Err(fork_publication_error(
                "cannot preflight fork message index",
                err,
                &mut stage,
                lifecycle,
                &key,
            ));
        }
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

    fn fail_file_remove(path: &Path, count: usize) {
        FILE_REMOVE_FAILURES
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
        recover_pending_forks_unlocked(&checked_storage, &mut lifecycle).unwrap();
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
