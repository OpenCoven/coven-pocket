//! Agentic chat sessions over the engine's query loop.
//!
//! A [`ChatSession`] owns a multi-turn conversation and drives
//! `claurst_query::run_query_loop` with the sandbox-safe file-tool profile:
//! the same Read/Grep/Glob/Edit/Write/ApplyPatch/BatchEdit/NotebookEdit
//! allowlist coven-code uses for hosted repair, with process, network, and
//! task tools excluded at registry build time (iOS forbids subprocesses).
//!
//! Containment has two layers:
//! 1. the allowlist keeps command/network/sub-agent surfaces out of the
//!    registry entirely, and
//! 2. every tool is wrapped in [`SandboxedTool`], which rejects inputs whose
//!    paths resolve outside the session's workspace root, so a prompt-injected
//!    model cannot read or write app-container files (for example stored
//!    provider credentials) through the file tools.

use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use claurst_api::client::ClientConfig;
use claurst_api::providers::CodexProvider;
use claurst_api::{AnthropicClient, ProviderRegistry};
use claurst_core::config::{Config, PermissionMode};
use claurst_core::cost::CostTracker;
use claurst_core::effort::EffortLevel;
use claurst_core::file_history::FileHistory;
use claurst_core::permissions::{PermissionDecision, PermissionHandler, PermissionRequest};
use claurst_core::types::Message;
use claurst_query::{run_query_loop, QueryConfig, QueryEvent, QueryOutcome};
use claurst_tools::{Tool, ToolContext, ToolResult};
use serde_json::Value;
use tokio::sync::mpsc;

use crate::{PocketError, PocketProvider};

/// The sandbox-safe tool allowlist, mirroring coven-code's hosted-repair
/// profile (`filter_tools_for_hosted_review` in the CLI). Only repository
/// file tools — never command/network/task/sub-agent/plugin/MCP surfaces.
/// The exhaustive `sandbox_profile_allows_only_file_tools` test guards
/// against a new engine tool silently leaking into this set.
const FILE_TOOLS: &[&str] = &[
    "Read",
    "Grep",
    "Glob",
    "Edit",
    "Write",
    "ApplyPatch",
    "BatchEdit",
    "NotebookEdit",
];

/// Streaming callbacks for a chat turn, implemented on the Swift side.
///
/// Callbacks arrive on Rust worker threads; the Swift implementation is
/// responsible for hopping to the main actor before touching UI. Exactly one
/// terminal callback (`on_done` or `on_error`) fires per `send`/`retry`.
#[uniffi::export(with_foreign)]
pub trait ChatDelegate: Send + Sync {
    /// Incremental assistant text.
    fn on_text(&self, text: String);
    /// Incremental extended-thinking text.
    fn on_thinking(&self, text: String);
    /// A tool call is about to execute.
    fn on_tool_start(&self, tool_id: String, tool_name: String, input_json: String);
    /// A tool call finished.
    fn on_tool_end(&self, tool_id: String, tool_name: String, result: String, is_error: bool);
    /// Informational status from the loop (retries, model fallback, …).
    fn on_status(&self, message: String);
    /// The turn finished. `stop_reason` is `end_turn`, `max_tokens`, or
    /// `cancelled`.
    fn on_done(&self, stop_reason: String);
    /// The turn failed. The conversation keeps the pending user message so
    /// `retry` can re-run it.
    fn on_error(&self, message: String);
}

/// A message in the persisted transcript, for rendering history.
#[derive(uniffi::Record)]
pub struct ChatMessage {
    /// `user` or `assistant`.
    pub role: String,
    /// Concatenated text content (tool blocks are omitted).
    pub text: String,
}

/// Provider-independent settings captured at session start.
struct SessionConfig {
    provider: PocketProvider,
    api_key: String,
    model: String,
    effort: Option<String>,
    workspace_dir: PathBuf,
}

/// A multi-turn agentic conversation bound to a workspace directory.
#[derive(uniffi::Object)]
pub struct ChatSession {
    config: SessionConfig,
    messages: tokio::sync::Mutex<Vec<Message>>,
    cancel: parking_lot::Mutex<tokio_util::sync::CancellationToken>,
    busy: AtomicBool,
}

#[uniffi::export(async_runtime = "tokio")]
impl ChatSession {
    /// Send a user message and run the agentic loop until the model ends its
    /// turn, an error occurs, or `stop` is called.
    pub async fn send(
        &self,
        prompt: String,
        delegate: Arc<dyn ChatDelegate>,
    ) -> Result<(), PocketError> {
        self.run_turn(Some(prompt), delegate).await
    }

    /// Re-run the loop after a failed turn without appending a new user
    /// message. Errors if the last message is already an assistant reply.
    pub async fn retry(&self, delegate: Arc<dyn ChatDelegate>) -> Result<(), PocketError> {
        self.run_turn(None, delegate).await
    }

    /// Cancel the in-flight turn, if any. The loop notices at the next
    /// cancellation point and reports `on_done("cancelled")`.
    pub fn stop(&self) {
        self.cancel.lock().cancel();
    }

    /// Whether a turn is currently running.
    pub fn is_busy(&self) -> bool {
        self.busy.load(Ordering::SeqCst)
    }

    /// The persisted transcript (text content only).
    pub async fn transcript(&self) -> Vec<ChatMessage> {
        let messages = self.messages.lock().await;
        messages
            .iter()
            .filter_map(|m| {
                let text = m.get_all_text();
                if text.is_empty() {
                    None
                } else {
                    Some(ChatMessage {
                        role: format!("{:?}", m.role).to_lowercase(),
                        text,
                    })
                }
            })
            .collect()
    }
}

impl ChatSession {
    async fn run_turn(
        &self,
        prompt: Option<String>,
        delegate: Arc<dyn ChatDelegate>,
    ) -> Result<(), PocketError> {
        if self.busy.swap(true, Ordering::SeqCst) {
            let message = "a turn is already running — stop it or wait".to_string();
            delegate.on_error(message.clone());
            return Err(PocketError::Engine { message });
        }
        // Hold the message lock for the whole turn; `busy` already serializes
        // callers, the lock just hands the loop `&mut Vec<Message>` safely.
        let result = async {
            let mut messages = self.messages.lock().await;
            if let Some(prompt) = prompt {
                messages.push(Message::user(prompt));
            } else {
                match messages.last() {
                    Some(last) if !matches!(last.role, claurst_core::types::Role::Assistant) => {}
                    _ => {
                        return Err(PocketError::Engine {
                            message: "nothing to retry — send a new message".to_string(),
                        });
                    }
                }
            }

            let cancel_token = {
                let mut guard = self.cancel.lock();
                *guard = tokio_util::sync::CancellationToken::new();
                guard.clone()
            };

            let (client, query_config, tool_ctx) = self.build_loop_inputs()?;
            let tools = sandbox_tools(&self.config.workspace_dir);

            let (event_tx, event_rx) = mpsc::unbounded_channel();
            let forwarder = spawn_event_forwarder(event_rx, delegate.clone());

            let outcome = run_query_loop(
                &client,
                &mut messages,
                &tools,
                &tool_ctx,
                &query_config,
                Arc::new(CostTracker::default()),
                Some(event_tx),
                cancel_token,
                None,
            )
            .await;

            // Drop the loop's sender clone by scope end; wait for the
            // forwarder to flush remaining events before the terminal call.
            let _ = forwarder.await;

            match outcome {
                QueryOutcome::EndTurn { .. } => {
                    delegate.on_done("end_turn".to_string());
                    Ok(())
                }
                QueryOutcome::MaxTokens { .. } => {
                    delegate.on_done("max_tokens".to_string());
                    Ok(())
                }
                QueryOutcome::Cancelled => {
                    delegate.on_done("cancelled".to_string());
                    Ok(())
                }
                QueryOutcome::BudgetExceeded {
                    cost_usd,
                    limit_usd,
                } => {
                    let message =
                        format!("budget exceeded: ${cost_usd:.2} of ${limit_usd:.2} limit");
                    delegate.on_error(message.clone());
                    Err(PocketError::Provider { message })
                }
                QueryOutcome::Error(err) => {
                    let message = err.to_string();
                    delegate.on_error(message.clone());
                    Err(PocketError::Provider { message })
                }
            }
        }
        .await;
        self.busy.store(false, Ordering::SeqCst);
        result
    }

    /// Build the client, query config, and tool context for one turn.
    fn build_loop_inputs(
        &self,
    ) -> Result<(AnthropicClient, QueryConfig, ToolContext), PocketError> {
        let workspace = &self.config.workspace_dir;

        // Shadow-git snapshots shell out to `git`, which does not exist on
        // iOS — keep them off regardless of the engine default.
        let mut engine_config = Config {
            project_dir: Some(workspace.clone()),
            workspace_paths: vec![workspace.clone()],
            auto_commits: Some(false),
            ..Default::default()
        };

        let mut registry = ProviderRegistry::new();
        let client_config = match self.config.provider {
            PocketProvider::Anthropic => ClientConfig {
                api_key: self.config.api_key.clone(),
                ..ClientConfig::default()
            },
            PocketProvider::Codex => {
                let provider =
                    CodexProvider::from_stored().ok_or_else(|| PocketError::Provider {
                        message: "not signed in to Codex — connect a ChatGPT account first"
                            .to_string(),
                    })?;
                registry.register(Arc::new(provider));
                engine_config.provider = Some("codex".to_string());
                // Empty key is fine: the loop dispatches to the registry's
                // Codex provider and never calls the Anthropic client.
                ClientConfig::default()
            }
        };
        let client = AnthropicClient::new(client_config).map_err(PocketError::engine)?;

        let query_config = QueryConfig {
            model: self.config.model.clone(),
            working_directory: Some(workspace.display().to_string()),
            effort_level: self.config.effort.as_deref().and_then(EffortLevel::parse),
            append_system_prompt: Some(
                "You are running inside Coven Pocket on iOS. Only repository file \
                 tools are available (no shell, no network tools); every path must \
                 stay inside the current workspace."
                    .to_string(),
            ),
            provider_registry: Some(Arc::new(registry)),
            ..QueryConfig::default()
        };

        let tool_ctx = ToolContext {
            working_dir: workspace.clone(),
            permission_mode: PermissionMode::Default,
            permission_handler: Arc::new(WorkspacePermissionHandler {
                root: workspace.clone(),
            }),
            cost_tracker: Arc::new(CostTracker::default()),
            session_id: format!("pocket-{}", uuid_like_suffix()),
            file_history: Arc::new(parking_lot::Mutex::new(FileHistory::new())),
            current_turn: Arc::new(AtomicUsize::new(0)),
            non_interactive: true,
            mcp_manager: None,
            config: engine_config,
            managed_agent_config: None,
            completion_notifier: None,
            pending_permissions: None,
            permission_manager: None,
            user_question_tx: None,
        };

        Ok((client, query_config, tool_ctx))
    }
}

/// Forward query-loop events to the delegate on a dedicated task so slow
/// Swift callbacks never stall tool execution.
fn spawn_event_forwarder(
    mut rx: mpsc::UnboundedReceiver<QueryEvent>,
    delegate: Arc<dyn ChatDelegate>,
) -> tokio::task::JoinHandle<()> {
    use claurst_api::streaming::{AnthropicStreamEvent, ContentDelta};
    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                QueryEvent::Stream(AnthropicStreamEvent::ContentBlockDelta {
                    delta: ContentDelta::TextDelta { text },
                    ..
                }) => delegate.on_text(text),
                QueryEvent::Stream(AnthropicStreamEvent::ContentBlockDelta {
                    delta: ContentDelta::ThinkingDelta { thinking },
                    ..
                }) => delegate.on_thinking(thinking),
                QueryEvent::Stream(_) => {}
                QueryEvent::ToolStart {
                    tool_name,
                    tool_id,
                    input_json,
                } => delegate.on_tool_start(tool_id, tool_name, input_json),
                QueryEvent::ToolEnd {
                    tool_name,
                    tool_id,
                    result,
                    is_error,
                } => delegate.on_tool_end(tool_id, tool_name, result, is_error),
                QueryEvent::Status(message) => delegate.on_status(message),
                QueryEvent::Error(message) => delegate.on_status(message),
                QueryEvent::TurnComplete { .. } | QueryEvent::TokenWarning { .. } => {}
            }
        }
    })
}

/// Cheap unique-enough suffix without pulling in a uuid dependency.
fn uuid_like_suffix() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs:x}{nanos:x}")
}

/// Create a new chat session. Exposed as a free function so `PocketEngine`
/// stays the single app-facing entry point (see `PocketEngine::start_chat`).
pub(crate) fn start_session(
    provider: PocketProvider,
    api_key: String,
    model: String,
    effort: Option<String>,
    workspace_dir: String,
) -> Result<Arc<ChatSession>, PocketError> {
    let workspace = PathBuf::from(&workspace_dir);
    if !workspace.is_absolute() {
        return Err(PocketError::Engine {
            message: format!("workspace_dir must be absolute, got {workspace_dir}"),
        });
    }
    std::fs::create_dir_all(&workspace).map_err(|e| PocketError::Engine {
        message: format!("cannot create workspace {workspace_dir}: {e}"),
    })?;
    // Resolve symlinks up front so containment checks compare real paths.
    let workspace = workspace.canonicalize().map_err(|e| PocketError::Engine {
        message: format!("cannot resolve workspace {workspace_dir}: {e}"),
    })?;
    Ok(Arc::new(ChatSession {
        config: SessionConfig {
            provider,
            api_key,
            model,
            effort,
            workspace_dir: workspace,
        },
        messages: tokio::sync::Mutex::new(Vec::new()),
        cancel: parking_lot::Mutex::new(tokio_util::sync::CancellationToken::new()),
        busy: AtomicBool::new(false),
    }))
}

// ---------------------------------------------------------------------------
// Sandbox profile
// ---------------------------------------------------------------------------

/// Build the sandboxed tool registry: allowlisted file tools, each wrapped in
/// workspace path containment.
pub(crate) fn sandbox_tools(workspace: &Path) -> Vec<Box<dyn Tool>> {
    claurst_tools::all_tools()
        .into_iter()
        .filter(|tool| FILE_TOOLS.contains(&tool.name()))
        .map(|tool| {
            Box::new(SandboxedTool {
                inner: tool,
                root: workspace.to_path_buf(),
            }) as Box<dyn Tool>
        })
        .collect()
}

/// Wraps an engine tool and rejects inputs whose paths escape the workspace.
///
/// The engine's file tools resolve relative paths against the working
/// directory but accept absolute paths and `..` traversal as-is; on iOS that
/// would expose the whole app container (including stored credentials) to a
/// prompt-injected model. This wrapper validates every path-carrying input
/// field before delegating.
struct SandboxedTool {
    inner: Box<dyn Tool>,
    root: PathBuf,
}

#[async_trait::async_trait]
impl Tool for SandboxedTool {
    fn name(&self) -> &str {
        self.inner.name()
    }

    fn description(&self) -> &str {
        self.inner.description()
    }

    fn permission_level(&self) -> claurst_tools::PermissionLevel {
        self.inner.permission_level()
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    async fn execute(&self, input: Value, ctx: &ToolContext) -> ToolResult {
        if let Err(path) = validate_tool_paths(self.inner.name(), &input, &self.root) {
            return ToolResult::error(format!(
                "path {path:?} is outside the workspace — only paths under \
                 {} are allowed",
                self.root.display()
            ));
        }
        self.inner.execute(input, ctx).await
    }
}

/// Check every path-carrying field of `input` for tool `name` against `root`.
/// Returns the offending path on failure.
fn validate_tool_paths(name: &str, input: &Value, root: &Path) -> Result<(), String> {
    let mut candidates: Vec<String> = Vec::new();
    let mut collect = |value: Option<&Value>| {
        if let Some(s) = value.and_then(Value::as_str) {
            candidates.push(s.to_string());
        }
    };

    match name {
        "Read" | "Edit" | "Write" => collect(input.get("file_path")),
        "NotebookEdit" => collect(input.get("notebook_path")),
        // For Grep/Glob `path` is an optional search root.
        "Grep" | "Glob" => collect(input.get("path")),
        "BatchEdit" => {
            if let Some(edits) = input.get("edits").and_then(Value::as_array) {
                for edit in edits {
                    collect(edit.get("file_path"));
                }
            }
        }
        "ApplyPatch" => {
            if let Some(patch) = input.get("patch").and_then(Value::as_str) {
                candidates.extend(patch_target_paths(patch));
            }
        }
        // Allowlisted tools are enumerated above; anything else in the
        // registry is a bug caught by the exhaustive profile test.
        _ => {}
    }

    for candidate in candidates {
        if !path_is_contained(&candidate, root) {
            return Err(candidate);
        }
    }
    Ok(())
}

/// Extract target paths from a unified diff (`+++ b/<path>` / `+++ <path>`
/// headers), mirroring the engine's `ApplyPatch` parser.
fn patch_target_paths(patch: &str) -> Vec<String> {
    patch
        .lines()
        .filter_map(|line| line.strip_prefix("+++ "))
        .map(|rest| {
            let rest = rest.trim();
            rest.strip_prefix("b/").unwrap_or(rest).to_string()
        })
        .filter(|p| !p.is_empty() && p != "/dev/null")
        .collect()
}

/// Whether `candidate` (absolute or workspace-relative) stays inside `root`
/// after lexical normalization. `root` must be canonicalized. Symlink escape
/// is not a vector here: the allowlisted tools only create regular files, and
/// the workspace starts empty under the app container.
fn path_is_contained(candidate: &str, root: &Path) -> bool {
    let joined = {
        let p = Path::new(candidate);
        if p.is_absolute() {
            p.to_path_buf()
        } else {
            root.join(p)
        }
    };

    let mut normalized = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::ParentDir => {
                if !normalized.pop() {
                    return false;
                }
            }
            Component::CurDir => {}
            other => normalized.push(other),
        }
    }
    normalized.starts_with(root)
}

/// Allows any operation whose paths stay inside the workspace root.
///
/// The [`SandboxedTool`] wrapper already validates structured tool inputs;
/// this handler is the second gate for the engine's own permission requests.
/// Requests that carry a path are checked against the root; path-less
/// requests are allowed because the wrapper has validated the real inputs.
struct WorkspacePermissionHandler {
    root: PathBuf,
}

impl WorkspacePermissionHandler {
    fn decide(&self, request: &PermissionRequest) -> PermissionDecision {
        match request.path.as_deref() {
            Some(path) if !path_is_contained(path, &self.root) => PermissionDecision::Deny,
            _ => PermissionDecision::Allow,
        }
    }
}

impl PermissionHandler for WorkspacePermissionHandler {
    fn check_permission(&self, request: &PermissionRequest) -> PermissionDecision {
        self.decide(request)
    }

    fn request_permission(&self, request: &PermissionRequest) -> PermissionDecision {
        self.decide(request)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Exhaustive guard mirroring coven-code's
    /// `hosted_repair_allows_only_repository_file_tools`: every engine tool is
    /// either explicitly allowlisted or explicitly excluded. A new engine tool
    /// fails the catch-all until it is classified here.
    #[test]
    fn sandbox_profile_allows_only_file_tools() {
        let excluded: &[&str] = &[
            "Bash",
            "WebFetch",
            "WebSearch",
            "TaskCreate",
            "TaskGet",
            "TaskUpdate",
            "TaskList",
            "TaskStop",
            "TaskOutput",
            "TodoWrite",
            "AskUserQuestion",
            "EnterPlanMode",
            "ExitPlanMode",
            "PowerShell",
            "Sleep",
            "CronCreate",
            "CronDelete",
            "CronList",
            "EnterWorktree",
            "ExitWorktree",
            "ListMcpResources",
            "ReadMcpResource",
            "ToolSearch",
            "LSP",
            "Brief",
            "Config",
            "SendMessage",
            "Skill",
            "REPL",
            "TeamCreate",
            "TeamDelete",
            "StructuredOutput",
            "mcp__auth",
            "RemoteTrigger",
            "monitor",
            "GoalComplete",
            "computer",
        ];

        let sandbox = sandbox_tools(Path::new("/tmp/pocket-test"));
        let sandbox_names: Vec<&str> = sandbox.iter().map(|t| t.name()).collect();

        for tool in claurst_tools::all_tools() {
            let name = tool.name();
            if FILE_TOOLS.contains(&name) {
                assert!(
                    sandbox_names.contains(&name),
                    "allowlisted tool {name} missing from sandbox registry"
                );
            } else {
                assert!(
                    !sandbox_names.contains(&name),
                    "non-file tool {name} leaked into the sandbox registry"
                );
                // Catch-all: every non-allowlisted engine tool must be
                // explicitly classified as excluded.
                assert!(
                    excluded.contains(&name),
                    "new engine tool {name:?} is neither allowlisted nor excluded — \
                     classify it in FILE_TOOLS or `excluded`"
                );
            }
        }

        assert_eq!(
            sandbox_names.len(),
            FILE_TOOLS.len(),
            "sandbox registry size must match the allowlist"
        );
    }

    #[test]
    fn contained_paths_accept_workspace_and_reject_escape() {
        let root = Path::new("/workspace/project");
        assert!(path_is_contained("src/main.rs", root));
        assert!(path_is_contained("/workspace/project/a/b.txt", root));
        assert!(path_is_contained("a/../b.txt", root));
        assert!(!path_is_contained("../other", root));
        assert!(!path_is_contained("/workspace/other", root));
        assert!(!path_is_contained("/etc/passwd", root));
        assert!(!path_is_contained("a/../../escape", root));
        // Prefix trickery: /workspace/project-evil must not match.
        assert!(!path_is_contained("/workspace/project-evil/x", root));
    }

    #[test]
    fn tool_inputs_are_validated_per_tool() {
        let root = Path::new("/ws");
        let ok = serde_json::json!({ "file_path": "notes.md" });
        assert!(validate_tool_paths("Write", &ok, root).is_ok());

        let escape = serde_json::json!({ "file_path": "/etc/hosts" });
        assert!(validate_tool_paths("Write", &escape, root).is_err());
        assert!(validate_tool_paths("Read", &escape, root).is_err());
        assert!(validate_tool_paths("Edit", &escape, root).is_err());

        let notebook = serde_json::json!({ "notebook_path": "../nb.ipynb" });
        assert!(validate_tool_paths("NotebookEdit", &notebook, root).is_err());

        let grep_ok = serde_json::json!({ "pattern": "x" });
        assert!(validate_tool_paths("Grep", &grep_ok, root).is_ok());
        let grep_escape = serde_json::json!({ "pattern": "x", "path": "/private" });
        assert!(validate_tool_paths("Grep", &grep_escape, root).is_err());

        let batch = serde_json::json!({
            "edits": [
                { "file_path": "ok.txt", "old_string": "a", "new_string": "b" },
                { "file_path": "../../escape.txt", "old_string": "a", "new_string": "b" }
            ]
        });
        assert!(validate_tool_paths("BatchEdit", &batch, root).is_err());
    }

    #[test]
    fn apply_patch_paths_are_extracted_and_checked() {
        let root = Path::new("/ws");
        let ok_patch = "--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -1 +1 @@\n-a\n+b\n";
        let input = serde_json::json!({ "patch": ok_patch });
        assert!(validate_tool_paths("ApplyPatch", &input, root).is_ok());

        let escape_patch = "--- a/x\n+++ b/../../etc/cron\n@@ -1 +1 @@\n-a\n+b\n";
        let input = serde_json::json!({ "patch": escape_patch });
        assert!(validate_tool_paths("ApplyPatch", &input, root).is_err());

        assert_eq!(
            patch_target_paths("+++ b/a.txt\n+++ /dev/null\n+++ b/c/d.txt"),
            vec!["a.txt".to_string(), "c/d.txt".to_string()]
        );
    }

    #[test]
    fn workspace_permission_handler_gates_paths() {
        let handler = WorkspacePermissionHandler {
            root: PathBuf::from("/ws"),
        };
        let request = |path: Option<&str>| PermissionRequest {
            tool_name: "Write".to_string(),
            description: "test".to_string(),
            details: None,
            is_read_only: false,
            path: path.map(String::from),
            working_dir: Some(PathBuf::from("/ws")),
            allowed_roots: vec![],
            context_description: None,
        };
        assert!(matches!(
            handler.request_permission(&request(Some("/ws/file.txt"))),
            PermissionDecision::Allow
        ));
        assert!(matches!(
            handler.request_permission(&request(Some("/etc/passwd"))),
            PermissionDecision::Deny
        ));
        assert!(matches!(
            handler.request_permission(&request(None)),
            PermissionDecision::Allow
        ));
    }

    #[test]
    fn session_rejects_relative_workspace() {
        let err = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            "relative/dir".to_string(),
        );
        assert!(err.is_err());
    }
}
