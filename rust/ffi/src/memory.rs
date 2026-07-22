//! Workspace memory: AGENTS.md context assembly and the memdir browser.
//!
//! Two engine surfaces, re-exposed for the app:
//!
//! 1. **Project context** — the hierarchical `AGENTS.md` chain
//!    (`claurst_core::claudemd`) plus the workspace's auto-memory notes
//!    (`claurst_core::memdir`), composed into one capped text block the
//!    chat session can append to its system prompt.
//! 2. **Memdir CRUD** — list/read/write/delete for the notes themselves,
//!    so the user can curate what future sessions see.
//!
//! Filenames are validated here: the memdir lives outside the workspace
//! sandbox, so the FFI is the only writer and must refuse traversal.

use std::path::PathBuf;

use claurst_core::claudemd::{load_all_memory_files_with_options, MemoryLoadOptions, MemoryScope};
use claurst_core::memdir::{auto_memory_path, scan_memory_dir};

use crate::PocketError;

/// Total context budget. Beyond this the block is cut and flagged, keeping
/// prompts bounded even with a packed memdir.
const MAX_CONTEXT_BYTES: usize = 48 * 1024;

/// One note in the workspace memdir (metadata only; content loads on read).
#[derive(Debug, Clone, uniffi::Record)]
pub struct MemoryNote {
    pub filename: String,
    /// `name:` frontmatter, empty when absent.
    pub name: String,
    /// `description:` frontmatter, empty when absent.
    pub description: String,
    /// `type:` frontmatter (`user|feedback|project|reference`), empty when
    /// absent or unrecognised.
    pub note_type: String,
    /// Modification time, seconds since the UNIX epoch.
    pub modified_secs: u64,
}

/// The composed system-prompt addition for a workspace.
#[derive(Debug, uniffi::Record)]
pub struct ProjectContext {
    /// Ready-to-inject text; empty when nothing is configured.
    pub text: String,
    /// Human-readable source labels, in injection order.
    pub sources: Vec<String>,
    /// True when the budget cut content.
    pub truncated: bool,
}

fn engine_err(err: impl std::fmt::Display) -> PocketError {
    PocketError::Engine {
        message: err.to_string(),
    }
}

/// The memdir for a workspace, as the engine computes it.
pub(crate) fn memdir_path(workspace_dir: &str) -> PathBuf {
    auto_memory_path(std::path::Path::new(workspace_dir))
}

/// Reject anything that is not a plain `*.md` filename inside the memdir.
fn validate_filename(filename: &str) -> Result<(), PocketError> {
    let plain = !filename.is_empty()
        && !filename.contains(['/', '\\'])
        && !filename.starts_with('.')
        && filename.ends_with(".md")
        && filename != "MEMORY.md";
    if plain {
        Ok(())
    } else {
        Err(engine_err(format!(
            "invalid memory filename '{filename}': must be a plain .md name"
        )))
    }
}

fn scope_label(scope: &MemoryScope) -> &'static str {
    match scope {
        MemoryScope::Managed => "managed rules",
        MemoryScope::User => "user AGENTS.md",
        MemoryScope::Project => "project AGENTS.md",
        MemoryScope::Local => "local AGENTS.md",
    }
}

pub(crate) fn list_notes(workspace_dir: &str) -> Vec<MemoryNote> {
    scan_memory_dir(&memdir_path(workspace_dir))
        .into_iter()
        .map(|meta| MemoryNote {
            filename: meta.filename,
            name: meta.name.unwrap_or_default(),
            description: meta.description.unwrap_or_default(),
            note_type: meta
                .memory_type
                .map(|kind| kind.as_str().to_string())
                .unwrap_or_default(),
            modified_secs: meta.modified_secs,
        })
        .collect()
}

pub(crate) fn read_note(workspace_dir: &str, filename: &str) -> Result<String, PocketError> {
    validate_filename(filename)?;
    std::fs::read_to_string(memdir_path(workspace_dir).join(filename)).map_err(engine_err)
}

pub(crate) fn write_note(
    workspace_dir: &str,
    filename: &str,
    content: &str,
) -> Result<(), PocketError> {
    validate_filename(filename)?;
    let dir = memdir_path(workspace_dir);
    std::fs::create_dir_all(&dir).map_err(engine_err)?;
    std::fs::write(dir.join(filename), content).map_err(engine_err)
}

pub(crate) fn delete_note(workspace_dir: &str, filename: &str) -> Result<(), PocketError> {
    validate_filename(filename)?;
    std::fs::remove_file(memdir_path(workspace_dir).join(filename)).map_err(engine_err)
}

/// Compose the AGENTS.md chain + memdir notes into one bounded block.
///
/// Workspace scopes only (`AGENTS.md` / `CLAUDE.md` at the project root and
/// `.coven-code/` override): there is no user-level `~/.coven-code` on a
/// sandboxed device, and skipping it keeps the pass hermetic.
pub(crate) fn project_context(workspace_dir: &str) -> ProjectContext {
    let workspace = std::path::Path::new(workspace_dir);
    let mut builder = ContextBuilder::default();

    let options = MemoryLoadOptions {
        allow_user_memory: false,
        allow_managed_rules: false,
        ..MemoryLoadOptions::local()
    };
    for file in load_all_memory_files_with_options(workspace, &options) {
        builder.push(
            format!("{} ({})", scope_label(&file.scope), file.path.display()),
            &file.content,
        );
    }

    let memdir = memdir_path(workspace_dir);
    for meta in scan_memory_dir(&memdir) {
        if let Ok(content) = std::fs::read_to_string(&meta.path) {
            let label = meta
                .name
                .filter(|name| !name.is_empty())
                .unwrap_or_else(|| meta.filename.clone());
            builder.push(format!("memory: {label}"), &content);
        }
    }

    builder.finish()
}

/// Accumulates labeled sections under [`MAX_CONTEXT_BYTES`].
#[derive(Default)]
struct ContextBuilder {
    text: String,
    sources: Vec<String>,
    truncated: bool,
}

impl ContextBuilder {
    fn push(&mut self, header: String, body: &str) {
        if self.truncated {
            return;
        }
        let remaining = MAX_CONTEXT_BYTES.saturating_sub(self.text.len());
        let section = format!("\n## {header}\n\n{}\n", body.trim_end());
        if section.len() > remaining {
            self.truncated = true;
            return;
        }
        self.text.push_str(&section);
        self.sources.push(header);
    }

    fn finish(self) -> ProjectContext {
        let text = if self.text.is_empty() {
            String::new()
        } else {
            format!("# Project context\n{}", self.text)
        };
        ProjectContext {
            text,
            sources: self.sources,
            truncated: self.truncated,
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Serialize env-dependent tests: `auto_memory_path` reads
    /// `COVEN_CODE_REMOTE_MEMORY_DIR`, which is process-global.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    pub(crate) struct MemdirGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
        pub(crate) workspace: PathBuf,
        base: PathBuf,
    }

    pub(crate) fn setup(tag: &str) -> MemdirGuard {
        let lock = ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let unique = format!("{}-{}", std::process::id(), tag);
        let workspace = std::env::temp_dir().join(format!("pocket-mem-ws-{unique}"));
        let base = std::env::temp_dir().join(format!("pocket-mem-base-{unique}"));
        let _ = std::fs::remove_dir_all(&workspace);
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::create_dir_all(&base).unwrap();
        std::env::set_var("COVEN_CODE_REMOTE_MEMORY_DIR", &base);
        // Hermetic AGENTS.md chain: point the engine's config home at the
        // scratch dir so a developer's real ~/.coven-code never leaks in.
        std::env::set_var("COVEN_CODE_HOME", base.join("home"));
        MemdirGuard {
            _lock: lock,
            workspace,
            base,
        }
    }

    impl Drop for MemdirGuard {
        fn drop(&mut self) {
            std::env::remove_var("COVEN_CODE_REMOTE_MEMORY_DIR");
            std::env::remove_var("COVEN_CODE_HOME");
            let _ = std::fs::remove_dir_all(&self.workspace);
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    impl MemdirGuard {
        fn workspace_str(&self) -> &str {
            self.workspace.to_str().unwrap()
        }
    }

    #[test]
    fn note_roundtrip_and_listing() {
        let guard = setup("roundtrip");
        let ws = guard.workspace_str();

        write_note(
            ws,
            "team_prefs.md",
            "---\nname: Team prefs\ntype: user\n---\nUse spaces.",
        )
        .unwrap();
        let notes = list_notes(ws);
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].filename, "team_prefs.md");
        assert_eq!(notes[0].name, "Team prefs");
        assert_eq!(notes[0].note_type, "user");

        assert!(read_note(ws, "team_prefs.md")
            .unwrap()
            .contains("Use spaces."));
        delete_note(ws, "team_prefs.md").unwrap();
        assert!(list_notes(ws).is_empty());
    }

    #[test]
    fn traversal_and_junk_filenames_are_refused() {
        let guard = setup("junk");
        let ws = guard.workspace_str();
        for bad in [
            "../evil.md",
            "a/b.md",
            "",
            ".hidden.md",
            "notes.txt",
            "MEMORY.md",
        ] {
            assert!(write_note(ws, bad, "x").is_err(), "accepted {bad:?}");
            assert!(read_note(ws, bad).is_err());
            assert!(delete_note(ws, bad).is_err());
        }
    }

    #[test]
    fn context_includes_agents_md_and_memdir_notes() {
        let guard = setup("context");
        let ws = guard.workspace_str();
        std::fs::write(guard.workspace.join("AGENTS.md"), "Always run the linter.").unwrap();
        write_note(
            ws,
            "incident.md",
            "---\nname: Incident 12\n---\nRollback steps…",
        )
        .unwrap();

        let context = project_context(ws);

        assert!(context.text.starts_with("# Project context"));
        assert!(context.text.contains("Always run the linter."));
        assert!(context.text.contains("Rollback steps…"));
        assert!(!context.truncated);
        assert!(context
            .sources
            .iter()
            .any(|source| source.starts_with("project AGENTS.md")));
        assert!(context
            .sources
            .iter()
            .any(|source| source == "memory: Incident 12"));
    }

    #[test]
    fn context_is_empty_without_any_sources() {
        let guard = setup("empty");
        let context = project_context(guard.workspace_str());
        assert!(context.text.is_empty());
        assert!(context.sources.is_empty());
        assert!(!context.truncated);
    }

    #[test]
    fn context_respects_the_budget() {
        let guard = setup("budget");
        let ws = guard.workspace_str();
        write_note(ws, "small.md", "keep me").unwrap();
        write_note(ws, "huge.md", &"x".repeat(MAX_CONTEXT_BYTES)).unwrap();

        let context = project_context(ws);

        assert!(context.truncated);
        assert!(context.text.len() <= MAX_CONTEXT_BYTES + 64);
    }
}
