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

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering};
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
use claurst_tools::{PermissionLevel, Tool, ToolContext, ToolResult};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

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
    /// A write tool wants to run in `Default` mode. Show an approval sheet
    /// and deliver the answer through `responder`; releasing the responder
    /// without answering denies the call.
    fn on_permission_request(
        &self,
        request: ChatPermissionRequest,
        responder: Arc<ChatPermissionResponder>,
    );
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

/// How write tools are gated. Read-only tools always run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChatPermissionMode {
    /// Every write asks for approval (unless allowed for the session).
    Default,
    /// File edits run without asking; the workspace sandbox still applies.
    AcceptEdits,
    /// Read-only: write tools are refused outright.
    Plan,
}

/// The user's answer to an approval request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChatPermissionDecision {
    /// Run this call.
    Allow,
    /// Run this call and stop asking for this tool for the session.
    AllowSession,
    /// Refuse this call; the model sees the refusal and can continue.
    Deny,
}

/// A pending approval shown to the user.
#[derive(uniffi::Record)]
pub struct ChatPermissionRequest {
    /// Unique per session, for correlating UI state.
    pub request_id: u64,
    /// Engine tool name (`Edit`, `Write`, …).
    pub tool_name: String,
    /// Workspace-relative target paths, comma-separated for multi-file calls.
    pub paths: String,
    /// Proposed-change preview (truncated diff/content), empty when the tool
    /// input has nothing meaningful to show.
    pub preview: String,
}

/// One-shot answer channel handed to the UI with each approval request.
///
/// Dropping it without responding counts as a denial, so a dismissed sheet
/// can never hang the turn.
#[derive(uniffi::Object)]
pub struct ChatPermissionResponder {
    tx: parking_lot::Mutex<Option<oneshot::Sender<ChatPermissionDecision>>>,
}

#[uniffi::export]
impl ChatPermissionResponder {
    /// Deliver the user's decision. Only the first call has an effect.
    pub fn respond(&self, decision: ChatPermissionDecision) {
        if let Some(tx) = self.tx.lock().take() {
            let _ = tx.send(decision);
        }
    }
}

/// Mutable permission state shared by a session and its sandboxed tools.
pub(crate) struct PermissionState {
    mode: AtomicU8,
    request_counter: AtomicU64,
    session_allowed: parking_lot::Mutex<HashSet<String>>,
}

impl PermissionState {
    fn new(mode: ChatPermissionMode) -> Self {
        Self {
            mode: AtomicU8::new(mode_to_u8(mode)),
            request_counter: AtomicU64::new(0),
            session_allowed: parking_lot::Mutex::new(HashSet::new()),
        }
    }

    fn mode(&self) -> ChatPermissionMode {
        mode_from_u8(self.mode.load(Ordering::SeqCst))
    }

    fn set_mode(&self, mode: ChatPermissionMode) {
        self.mode.store(mode_to_u8(mode), Ordering::SeqCst);
    }
}

fn mode_to_u8(mode: ChatPermissionMode) -> u8 {
    match mode {
        ChatPermissionMode::Default => 0,
        ChatPermissionMode::AcceptEdits => 1,
        ChatPermissionMode::Plan => 2,
    }
}

fn mode_from_u8(raw: u8) -> ChatPermissionMode {
    match raw {
        1 => ChatPermissionMode::AcceptEdits,
        2 => ChatPermissionMode::Plan,
        _ => ChatPermissionMode::Default,
    }
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
    perms: Arc<PermissionState>,
    session_id: String,
    /// `None` for unpersisted sessions (no storage dir configured).
    persistence: Option<crate::sessions::SessionPersistence>,
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

    /// Stable UUID identifying this session in the on-device store.
    pub fn session_id(&self) -> String {
        self.session_id.clone()
    }

    /// The active permission mode.
    pub fn permission_mode(&self) -> ChatPermissionMode {
        self.perms.mode()
    }

    /// Switch permission modes. Applies to the next tool call, including
    /// calls later in an in-flight turn. Session-scoped approvals persist
    /// across mode changes.
    pub fn set_permission_mode(&self, mode: ChatPermissionMode) {
        self.perms.set_mode(mode);
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
            let err = PocketError::Engine {
                message: "a turn is already running — stop it or wait".to_string(),
            };
            delegate.on_error(err.to_string());
            return Err(err);
        }
        // Hold the message lock for the whole turn; `busy` already serializes
        // callers, the lock just hands the loop `&mut Vec<Message>` safely.
        //
        // The inner block never touches the terminal callbacks: it resolves to
        // a stop reason or an error, and the single dispatch below guarantees
        // exactly one `on_done`/`on_error` per turn — including setup
        // failures before the loop starts.
        let outcome = async {
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
            // Persist the user message before the network round-trip so a
            // killed app still finds it on resume. Best-effort: a storage
            // failure must not take the turn down.
            self.persist_new(&messages, &delegate).await;

            let cancel_token = {
                let mut guard = self.cancel.lock();
                *guard = tokio_util::sync::CancellationToken::new();
                guard.clone()
            };

            let (client, query_config, tool_ctx) = self.build_loop_inputs()?;
            let tools = sandbox_tools(
                &self.config.workspace_dir,
                self.perms.clone(),
                Some(delegate.clone()),
            );

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

            // Persist whatever the loop appended (assistant turns and
            // tool-result carriers), whatever the outcome.
            self.persist_new(&messages, &delegate).await;

            match outcome {
                QueryOutcome::EndTurn { .. } => Ok("end_turn"),
                QueryOutcome::MaxTokens { .. } => Ok("max_tokens"),
                QueryOutcome::Cancelled => Ok("cancelled"),
                QueryOutcome::BudgetExceeded {
                    cost_usd,
                    limit_usd,
                } => Err(PocketError::Provider {
                    message: format!("budget exceeded: ${cost_usd:.2} of ${limit_usd:.2} limit"),
                }),
                QueryOutcome::Error(err) => Err(PocketError::Provider {
                    message: err.to_string(),
                }),
            }
        }
        .await;
        self.busy.store(false, Ordering::SeqCst);
        match outcome {
            Ok(stop_reason) => {
                delegate.on_done(stop_reason.to_string());
                Ok(())
            }
            Err(err) => {
                delegate.on_error(err.to_string());
                Err(err)
            }
        }
    }

    /// Best-effort persistence of the not-yet-stored message suffix. Storage
    /// failures surface as a status line rather than failing the turn.
    async fn persist_new(&self, messages: &[Message], delegate: &Arc<dyn ChatDelegate>) {
        let Some(persistence) = &self.persistence else {
            return;
        };
        if let Err(err) = persistence.persist_new(messages).await {
            delegate.on_status(format!("session not saved: {err}"));
        }
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
    permission_mode: ChatPermissionMode,
    storage_dir: Option<String>,
) -> Result<Arc<ChatSession>, PocketError> {
    let workspace = resolve_workspace(&workspace_dir)?;
    let session_id = uuid::Uuid::new_v4().to_string();
    let persistence = storage_dir
        .map(|dir| {
            crate::sessions::SessionPersistence::create(&dir, session_id.clone(), model.clone())
        })
        .transpose()?;
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
        perms: Arc::new(PermissionState::new(permission_mode)),
        session_id,
        persistence,
    }))
}

/// Rebuild a persisted session at its stored head. New turns append to the
/// same transcript. Provider settings come from the caller (they may differ
/// from the ones the session was created with).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn resume_session(
    provider: PocketProvider,
    api_key: String,
    model: String,
    effort: Option<String>,
    workspace_dir: String,
    permission_mode: ChatPermissionMode,
    storage_dir: String,
    session_id: String,
) -> Result<Arc<ChatSession>, PocketError> {
    let workspace = resolve_workspace(&workspace_dir)?;
    let (messages, last_uuid) =
        crate::sessions::load_session_messages(&storage_dir, &session_id).await?;
    let persistence = crate::sessions::SessionPersistence::resumed(
        &storage_dir,
        session_id.clone(),
        model.clone(),
        messages.len(),
        last_uuid,
    )?;
    Ok(Arc::new(ChatSession {
        config: SessionConfig {
            provider,
            api_key,
            model,
            effort,
            workspace_dir: workspace,
        },
        messages: tokio::sync::Mutex::new(messages),
        cancel: parking_lot::Mutex::new(tokio_util::sync::CancellationToken::new()),
        busy: AtomicBool::new(false),
        perms: Arc::new(PermissionState::new(permission_mode)),
        session_id,
        persistence: Some(persistence),
    }))
}

fn resolve_workspace(workspace_dir: &str) -> Result<PathBuf, PocketError> {
    let workspace = PathBuf::from(workspace_dir);
    if !workspace.is_absolute() {
        return Err(PocketError::Engine {
            message: format!("workspace_dir must be absolute, got {workspace_dir}"),
        });
    }
    std::fs::create_dir_all(&workspace).map_err(|e| PocketError::Engine {
        message: format!("cannot create workspace {workspace_dir}: {e}"),
    })?;
    // Resolve symlinks up front so containment checks compare real paths.
    workspace.canonicalize().map_err(|e| PocketError::Engine {
        message: format!("cannot resolve workspace {workspace_dir}: {e}"),
    })
}

// ---------------------------------------------------------------------------
// Sandbox profile
// ---------------------------------------------------------------------------

/// Build the sandboxed tool registry: allowlisted file tools, each wrapped in
/// workspace path containment and (for write tools) the permission gate.
///
/// `delegate` receives approval requests in `Default` mode; passing `None`
/// (tests, headless callers) makes `Default` behave like deny-on-write.
pub(crate) fn sandbox_tools(
    workspace: &Path,
    perms: Arc<PermissionState>,
    delegate: Option<Arc<dyn ChatDelegate>>,
) -> Vec<Box<dyn Tool>> {
    claurst_tools::all_tools()
        .into_iter()
        .filter(|tool| FILE_TOOLS.contains(&tool.name()))
        .map(|tool| {
            Box::new(SandboxedTool {
                inner: tool,
                root: workspace.to_path_buf(),
                perms: perms.clone(),
                delegate: delegate.clone(),
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
///
/// It is also the permission gate: write-level tools are refused in `Plan`
/// mode and routed through the approval delegate in `Default` mode. Doing
/// this here (instead of the engine's sync `PermissionHandler`) keeps the
/// user wait fully async — no runtime threads are blocked while a sheet is
/// on screen.
struct SandboxedTool {
    inner: Box<dyn Tool>,
    root: PathBuf,
    perms: Arc<PermissionState>,
    delegate: Option<Arc<dyn ChatDelegate>>,
}

impl SandboxedTool {
    /// Gate a write-level call according to the active mode. `Ok(())` means
    /// run it; `Err(result)` is returned to the model verbatim.
    async fn authorize_write(&self, input: &Value) -> Result<(), ToolResult> {
        match self.perms.mode() {
            ChatPermissionMode::AcceptEdits => Ok(()),
            ChatPermissionMode::Plan => Err(ToolResult::error(format!(
                "{} is not available in plan mode (read-only) — present a plan \
                 instead, and ask the user to switch modes to apply changes",
                self.inner.name()
            ))),
            ChatPermissionMode::Default => {
                if self
                    .perms
                    .session_allowed
                    .lock()
                    .contains(self.inner.name())
                {
                    return Ok(());
                }
                let Some(delegate) = &self.delegate else {
                    return Err(ToolResult::error(format!(
                        "{} requires approval but no approver is attached",
                        self.inner.name()
                    )));
                };

                let (tx, rx) = oneshot::channel();
                let request = ChatPermissionRequest {
                    request_id: self.perms.request_counter.fetch_add(1, Ordering::Relaxed),
                    tool_name: self.inner.name().to_string(),
                    paths: tool_paths_summary(self.inner.name(), input, &self.root),
                    preview: tool_input_preview(self.inner.name(), input),
                };
                delegate.on_permission_request(
                    request,
                    Arc::new(ChatPermissionResponder {
                        tx: parking_lot::Mutex::new(Some(tx)),
                    }),
                );

                // A dropped responder (dismissed sheet, released bridge)
                // resolves to RecvError, which denies.
                match rx.await {
                    Ok(ChatPermissionDecision::Allow) => Ok(()),
                    Ok(ChatPermissionDecision::AllowSession) => {
                        self.perms
                            .session_allowed
                            .lock()
                            .insert(self.inner.name().to_string());
                        Ok(())
                    }
                    Ok(ChatPermissionDecision::Deny) | Err(_) => Err(ToolResult::error(format!(
                        "the user denied this {} call — ask before retrying \
                         or adjust the approach",
                        self.inner.name()
                    ))),
                }
            }
        }
    }
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
        if self.inner.permission_level() == PermissionLevel::Write {
            if let Err(refusal) = self.authorize_write(&input).await {
                return refusal;
            }
        }
        self.inner.execute(input, ctx).await
    }
}

/// Check every path-carrying field of `input` for tool `name` against `root`.
/// Returns the offending path on failure.
fn validate_tool_paths(name: &str, input: &Value, root: &Path) -> Result<(), String> {
    for candidate in collect_tool_paths(name, input) {
        if !path_is_contained(&candidate, root) {
            return Err(candidate);
        }
    }
    Ok(())
}

/// Extract the path-carrying fields of a tool input.
fn collect_tool_paths(name: &str, input: &Value) -> Vec<String> {
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
    candidates
}

/// Deduplicated, workspace-relative target paths for the approval sheet.
fn tool_paths_summary(name: &str, input: &Value, root: &Path) -> String {
    let mut seen = HashSet::new();
    let mut parts: Vec<String> = Vec::new();
    for path in collect_tool_paths(name, input) {
        let display = Path::new(&path)
            .strip_prefix(root)
            .map(|p| p.display().to_string())
            .unwrap_or(path);
        let display = if display.is_empty() {
            ".".to_string()
        } else {
            display
        };
        if seen.insert(display.clone()) {
            parts.push(display);
        }
    }
    parts.join(", ")
}

const PREVIEW_LIMIT: usize = 600;

/// Truncate to `PREVIEW_LIMIT` characters on a char boundary.
fn truncate_preview(text: &str) -> String {
    if text.chars().count() <= PREVIEW_LIMIT {
        return text.to_string();
    }
    let cut: String = text.chars().take(PREVIEW_LIMIT).collect();
    format!("{cut}\n…")
}

/// A proposed-change preview for the approval sheet, per tool input shape.
fn tool_input_preview(name: &str, input: &Value) -> String {
    let text = |key: &str| {
        input
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    match name {
        "Edit" => {
            let old = text("old_string");
            let new = text("new_string");
            if old.is_empty() && new.is_empty() {
                String::new()
            } else {
                truncate_preview(&format!("- {old}\n+ {new}"))
            }
        }
        "Write" => truncate_preview(&text("content")),
        "NotebookEdit" => truncate_preview(&text("new_source")),
        "ApplyPatch" => truncate_preview(&text("patch")),
        "BatchEdit" => {
            let count = input
                .get("edits")
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0);
            format!("{count} edit(s)")
        }
        _ => String::new(),
    }
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

        let sandbox = sandbox_tools(
            Path::new("/tmp/pocket-test"),
            Arc::new(PermissionState::new(ChatPermissionMode::Default)),
            None,
        );
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
            ChatPermissionMode::Default,
            None,
        );
        assert!(err.is_err());
    }

    /// Records terminal callbacks so tests can assert the exactly-once
    /// contract on paths that fail before the query loop starts. Approval
    /// requests are answered with the configured decision (or dropped when
    /// `None`, exercising the deny-on-release path).
    #[derive(Default)]
    struct RecordingDelegate {
        done: parking_lot::Mutex<Vec<String>>,
        errors: parking_lot::Mutex<Vec<String>>,
        prompts: parking_lot::Mutex<Vec<ChatPermissionRequest>>,
        answer: Option<ChatPermissionDecision>,
    }

    impl RecordingDelegate {
        fn answering(decision: ChatPermissionDecision) -> Self {
            Self {
                answer: Some(decision),
                ..Self::default()
            }
        }
    }

    impl ChatDelegate for RecordingDelegate {
        fn on_text(&self, _text: String) {}
        fn on_thinking(&self, _text: String) {}
        fn on_tool_start(&self, _tool_id: String, _tool_name: String, _input_json: String) {}
        fn on_tool_end(
            &self,
            _tool_id: String,
            _tool_name: String,
            _result: String,
            _is_error: bool,
        ) {
        }
        fn on_status(&self, _message: String) {}
        fn on_permission_request(
            &self,
            request: ChatPermissionRequest,
            responder: Arc<ChatPermissionResponder>,
        ) {
            self.prompts.lock().push(request);
            if let Some(decision) = self.answer {
                responder.respond(decision);
            }
        }
        fn on_done(&self, stop_reason: String) {
            self.done.lock().push(stop_reason);
        }
        fn on_error(&self, message: String) {
            self.errors.lock().push(message);
        }
    }

    #[tokio::test]
    async fn retry_without_pending_message_emits_exactly_one_terminal_callback() {
        let workspace = std::env::temp_dir().join(format!("pocket-chat-{}", std::process::id()));
        std::fs::create_dir_all(&workspace).unwrap();
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
        )
        .unwrap();

        let delegate = Arc::new(RecordingDelegate::default());
        let result = session.retry(delegate.clone()).await;

        assert!(result.is_err());
        assert_eq!(delegate.done.lock().len(), 0);
        assert_eq!(
            delegate.errors.lock().len(),
            1,
            "setup failures must surface through exactly one on_error"
        );
        assert!(!session.is_busy());
        let _ = std::fs::remove_dir_all(&workspace);
    }

    // -- permission gate ----------------------------------------------------

    /// Write-level stub that records whether it ran.
    struct StubWriteTool {
        ran: Arc<AtomicBool>,
    }

    #[async_trait::async_trait]
    impl Tool for StubWriteTool {
        fn name(&self) -> &str {
            "Write"
        }
        fn description(&self) -> &str {
            "stub"
        }
        fn permission_level(&self) -> PermissionLevel {
            PermissionLevel::Write
        }
        fn input_schema(&self) -> Value {
            serde_json::json!({})
        }
        async fn execute(&self, _input: Value, _ctx: &ToolContext) -> ToolResult {
            self.ran.store(true, Ordering::SeqCst);
            ToolResult::success("written")
        }
    }

    fn gated_stub(
        mode: ChatPermissionMode,
        delegate: Option<Arc<dyn ChatDelegate>>,
    ) -> (SandboxedTool, Arc<AtomicBool>, Arc<PermissionState>) {
        let ran = Arc::new(AtomicBool::new(false));
        let perms = Arc::new(PermissionState::new(mode));
        let tool = SandboxedTool {
            inner: Box::new(StubWriteTool { ran: ran.clone() }),
            root: std::env::temp_dir(),
            perms: perms.clone(),
            delegate,
        };
        (tool, ran, perms)
    }

    fn write_input() -> Value {
        let path = std::env::temp_dir().join("gate-test.txt");
        serde_json::json!({ "file_path": path, "content": "hello" })
    }

    fn test_ctx() -> ToolContext {
        // Only fields the stub path touches matter; reuse the session builder
        // for a fully-populated context.
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            std::env::temp_dir().display().to_string(),
            ChatPermissionMode::Default,
            None,
        )
        .unwrap();
        let (_client, _config, ctx) = session.build_loop_inputs().unwrap();
        ctx
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn plan_mode_refuses_writes_without_prompting() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Allow));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Plan, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx()).await;

        assert!(result.is_error);
        assert!(!ran.load(Ordering::SeqCst), "plan mode must not execute");
        assert!(delegate.prompts.lock().is_empty(), "plan mode never asks");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn accept_edits_runs_writes_without_prompting() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Deny));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::AcceptEdits, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx()).await;

        assert!(!result.is_error);
        assert!(ran.load(Ordering::SeqCst));
        assert!(delegate.prompts.lock().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn default_mode_denial_blocks_execution() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Deny));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Default, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx()).await;

        assert!(result.is_error);
        assert!(!ran.load(Ordering::SeqCst));
        assert_eq!(delegate.prompts.lock().len(), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn default_mode_approval_executes() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Allow));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Default, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx()).await;

        assert!(!result.is_error);
        assert!(ran.load(Ordering::SeqCst));
        let prompts = delegate.prompts.lock();
        assert_eq!(prompts.len(), 1);
        assert_eq!(prompts[0].tool_name, "Write");
        assert!(prompts[0].preview.contains("hello"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn allow_session_skips_subsequent_prompts() {
        let delegate = Arc::new(RecordingDelegate::answering(
            ChatPermissionDecision::AllowSession,
        ));
        let (tool, ran, perms) = gated_stub(ChatPermissionMode::Default, Some(delegate.clone()));
        let ctx = test_ctx();

        assert!(!tool.execute(write_input(), &ctx).await.is_error);
        ran.store(false, Ordering::SeqCst);
        assert!(!tool.execute(write_input(), &ctx).await.is_error);

        assert!(ran.load(Ordering::SeqCst));
        assert_eq!(
            delegate.prompts.lock().len(),
            1,
            "allow-for-session must suppress the second prompt"
        );
        assert!(perms.session_allowed.lock().contains("Write"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn dropped_responder_denies() {
        // answer: None → the responder is dropped unanswered.
        let delegate = Arc::new(RecordingDelegate::default());
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Default, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx()).await;

        assert!(result.is_error);
        assert!(!ran.load(Ordering::SeqCst));
        assert_eq!(delegate.prompts.lock().len(), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn read_only_tools_bypass_the_gate() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Deny));
        let perms = Arc::new(PermissionState::new(ChatPermissionMode::Default));
        let workspace = std::env::temp_dir().canonicalize().unwrap();
        let tools = sandbox_tools(&workspace, perms, Some(delegate.clone()));
        let read = tools
            .iter()
            .find(|t| t.name() == "Read")
            .expect("Read tool in sandbox");
        let target = workspace.join("gate-read-test.txt");
        std::fs::write(&target, "content").unwrap();

        let result = read
            .execute(serde_json::json!({ "file_path": target }), &test_ctx())
            .await;

        assert!(!result.is_error);
        assert!(delegate.prompts.lock().is_empty());
        let _ = std::fs::remove_file(&target);
    }

    #[test]
    fn mode_roundtrip_and_paths_summary() {
        for mode in [
            ChatPermissionMode::Default,
            ChatPermissionMode::AcceptEdits,
            ChatPermissionMode::Plan,
        ] {
            assert_eq!(mode_from_u8(mode_to_u8(mode)), mode);
        }

        let root = Path::new("/ws");
        let summary = tool_paths_summary(
            "BatchEdit",
            &serde_json::json!({
                "edits": [
                    { "file_path": "/ws/a.txt" },
                    { "file_path": "/ws/b.txt" },
                    { "file_path": "/ws/a.txt" },
                ]
            }),
            root,
        );
        assert_eq!(summary, "a.txt, b.txt");
    }

    // -- session persistence -------------------------------------------------

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pocket-{label}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Build a persisted session and write one user + one assistant message
    /// through the same hook `run_turn` uses.
    async fn persisted_session(storage: &Path, workspace: &Path) -> Arc<ChatSession> {
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            Some(storage.display().to_string()),
        )
        .unwrap();
        let delegate: Arc<dyn ChatDelegate> = Arc::new(RecordingDelegate::default());
        {
            let mut messages = session.messages.lock().await;
            messages.push(Message::user("hello world\nsecond line"));
            session.persist_new(&messages, &delegate).await;
            messages.push(Message::assistant("hi there"));
            session.persist_new(&messages, &delegate).await;
            // Same length again: must be a no-op, not a duplicate append.
            session.persist_new(&messages, &delegate).await;
        }
        session
    }

    #[tokio::test]
    async fn persisted_session_shows_up_in_list_with_derived_title() {
        let storage = temp_dir("store");
        let workspace = temp_dir("ws");

        let session = persisted_session(&storage, &workspace).await;
        let listed = crate::sessions::list_sessions(&storage.display().to_string()).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].session_id, session.session_id());
        assert_eq!(listed[0].title, "hello world");
        assert_eq!(listed[0].model, "claude-test");
        assert_eq!(listed[0].message_count, 2);

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[tokio::test]
    async fn resume_restores_transcript_and_appends_to_same_record() {
        let storage = temp_dir("store");
        let workspace = temp_dir("ws");
        let storage_str = storage.display().to_string();

        let original = persisted_session(&storage, &workspace).await;
        let resumed = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str.clone(),
            original.session_id(),
        )
        .await
        .unwrap();

        assert_eq!(resumed.session_id(), original.session_id());
        let transcript = resumed.transcript().await;
        assert_eq!(transcript.len(), 2);
        assert_eq!(transcript[0].role, "user");
        assert!(transcript[0].text.contains("hello world"));
        assert_eq!(transcript[1].role, "assistant");
        assert_eq!(transcript[1].text, "hi there");

        // Appending after resume extends the same record without duplicating
        // the restored prefix.
        let delegate: Arc<dyn ChatDelegate> = Arc::new(RecordingDelegate::default());
        {
            let mut messages = resumed.messages.lock().await;
            messages.push(Message::user("follow-up"));
            resumed.persist_new(&messages, &delegate).await;
        }
        let listed = crate::sessions::list_sessions(&storage_str).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].message_count, 3);

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[tokio::test]
    async fn resume_unknown_session_errors() {
        let storage = temp_dir("store");
        let err = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            std::env::temp_dir().display().to_string(),
            ChatPermissionMode::Default,
            storage.display().to_string(),
            uuid::Uuid::new_v4().to_string(),
        )
        .await;
        assert!(err.is_err());
        let _ = std::fs::remove_dir_all(&storage);
    }

    #[tokio::test]
    async fn fork_copies_transcript_under_new_id() {
        let storage = temp_dir("store");
        let workspace = temp_dir("ws");
        let storage_str = storage.display().to_string();

        let original = persisted_session(&storage, &workspace).await;
        let fork_id = crate::sessions::fork_session(&storage_str, &original.session_id())
            .await
            .unwrap();
        assert_ne!(fork_id, original.session_id());

        let listed = crate::sessions::list_sessions(&storage_str).unwrap();
        assert_eq!(listed.len(), 2);
        let fork_row = listed
            .iter()
            .find(|s| s.session_id == fork_id)
            .expect("fork listed");
        assert_eq!(fork_row.title, "hello world");
        assert_eq!(fork_row.model, "claude-test");
        assert_eq!(fork_row.message_count, 2);

        // Deleting the original leaves the fork intact and resumable.
        crate::sessions::delete_session(&storage_str, &original.session_id()).unwrap();
        let listed = crate::sessions::list_sessions(&storage_str).unwrap();
        assert_eq!(listed.len(), 1);
        let resumed_fork = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str.clone(),
            fork_id,
        )
        .await
        .unwrap();
        assert_eq!(resumed_fork.transcript().await.len(), 2);

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[tokio::test]
    async fn delete_removes_session_and_blocks_resume() {
        let storage = temp_dir("store");
        let workspace = temp_dir("ws");
        let storage_str = storage.display().to_string();

        let session = persisted_session(&storage, &workspace).await;
        crate::sessions::delete_session(&storage_str, &session.session_id()).unwrap();
        assert!(crate::sessions::list_sessions(&storage_str)
            .unwrap()
            .is_empty());
        let err = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str,
            session.session_id(),
        )
        .await;
        assert!(err.is_err());

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[tokio::test]
    async fn unpersisted_session_stays_out_of_the_store() {
        let storage = temp_dir("store");
        let workspace = temp_dir("ws");

        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
        )
        .unwrap();
        assert!(uuid::Uuid::parse_str(&session.session_id()).is_ok());

        let delegate: Arc<dyn ChatDelegate> = Arc::new(RecordingDelegate::default());
        {
            let mut messages = session.messages.lock().await;
            messages.push(Message::user("hello"));
            session.persist_new(&messages, &delegate).await;
        }
        assert!(
            crate::sessions::list_sessions(&storage.display().to_string())
                .unwrap()
                .is_empty()
        );

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
