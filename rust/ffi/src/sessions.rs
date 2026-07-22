//! On-device persistence for chat sessions.
//!
//! Layout under an app-provided absolute `storage_dir`:
//!
//! ```text
//! {storage_dir}/index.sqlite               — engine SqliteSessionStore (list/search index)
//! {storage_dir}/transcripts/{uuid}.jsonl   — engine-format JSONL transcript (full fidelity)
//! ```
//!
//! Transcripts use the engine's `session_storage` wire format, so files are
//! readable by coven-code tooling and survive engine upgrades via its
//! forward-compatible parser. The SQLite index only serves the browser UI;
//! the JSONL file is the source of truth for restores.

use std::path::{Path, PathBuf};

use claurst_core::session_storage::{
    load_transcript, make_assistant_entry, make_user_entry, messages_from_transcript,
    write_transcript_entry, TranscriptEntry,
};
use claurst_core::types::{Message, Role};
use claurst_core::SqliteSessionStore;

use crate::PocketError;

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

fn transcript_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("transcripts").join(format!("{session_id}.jsonl"))
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

/// Load a persisted transcript for resuming: full messages plus the chain
/// tail needed to keep appending.
pub(crate) async fn load_session_messages(
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

/// Newest-first summaries for the browser.
pub fn list_sessions(storage_dir: &str) -> Result<Vec<ChatSessionSummary>, PocketError> {
    let root = storage_root(storage_dir)?;
    let store = index_store(&root)?;
    let rows = store
        .list_sessions()
        .map_err(|e| engine_err("cannot list sessions", e))?;
    Ok(rows
        .into_iter()
        .map(|s| ChatSessionSummary {
            session_id: s.id,
            title: s.title.unwrap_or_default(),
            model: s.model,
            created_at: s.created_at,
            updated_at: s.updated_at,
            message_count: s.message_count,
        })
        .collect())
}

/// Drop a session from the index and delete its transcript file.
pub fn delete_session(storage_dir: &str, session_id: &str) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    index_store(&root)?
        .delete_session(session_id)
        .map_err(|e| engine_err("cannot delete session", e))?;
    match std::fs::remove_file(transcript_file(&root, session_id)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(engine_err("cannot delete transcript", e)),
    }
}

/// Copy a session's transcript under a fresh id at its current head.
/// Returns the new session id.
pub async fn fork_session(storage_dir: &str, session_id: &str) -> Result<String, PocketError> {
    let (messages, _) = load_session_messages(storage_dir, session_id).await?;
    if messages.is_empty() {
        return Err(PocketError::Engine {
            message: format!("session {session_id} has no messages to fork"),
        });
    }
    let root = storage_root(storage_dir)?;

    // Model comes from the source's index row; the transcript doesn't carry it.
    let model = list_sessions(storage_dir)?
        .into_iter()
        .find(|s| s.session_id == session_id)
        .map(|s| s.model)
        .unwrap_or_default();

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
    Ok(new_id)
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn list_on_fresh_dir_is_empty_and_relative_dir_errors() {
        let dir = std::env::temp_dir().join(format!("pocket-list-{}", uuid::Uuid::new_v4()));
        assert!(list_sessions(&dir.display().to_string())
            .unwrap()
            .is_empty());
        assert!(list_sessions("relative/dir").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn fork_of_unknown_session_errors() {
        let dir = std::env::temp_dir().join(format!("pocket-fork-{}", uuid::Uuid::new_v4()));
        let err = fork_session(
            &dir.display().to_string(),
            &uuid::Uuid::new_v4().to_string(),
        )
        .await;
        assert!(err.is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
