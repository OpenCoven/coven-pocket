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

use crate::remote::{normalize_familiar_identity, FamiliarIdentity};
use crate::{PocketError, PocketProvider};

#[cfg(test)]
const TEST_IMMEDIATE_END_TURN_MODEL: &str = "coven-pocket-test-immediate-end-turn";

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
    familiar: Option<crate::remote::FamiliarIdentity>,
    /// The workspace AGENTS.md chain + memdir notes, composed once at
    /// session creation (the per-workspace "Memory" toggle). `None` when the
    /// toggle is off or nothing is configured; turns reuse the snapshot so
    /// no per-turn filesystem scans happen on the runtime thread.
    injected_context: Option<String>,
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
    #[cfg(test)]
    model_tool_loop_invocations: AtomicUsize,
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

    /// The durable goal state for this persisted session, if any.
    pub async fn goal_status(&self) -> Result<Option<crate::GoalSnapshot>, PocketError> {
        let storage = self.goal_storage()?;
        crate::goals::load(storage, self.session_id.clone()).await
    }

    /// Persist a pause before cancelling an in-flight goal turn.
    pub async fn pause_goal(&self) -> Result<crate::GoalSnapshot, PocketError> {
        let snapshot = crate::goals::pause(self.goal_storage()?, self.session_id.clone()).await?;
        self.stop();
        Ok(snapshot)
    }

    /// Remove a goal before cancelling an in-flight goal turn.
    pub async fn clear_goal(&self) -> Result<(), PocketError> {
        crate::goals::clear(self.goal_storage()?, self.session_id.clone()).await?;
        self.stop();
        Ok(())
    }

    /// Create and run a durable autonomous goal. Internal continuation prompts
    /// are never added to the visible user transcript.
    pub async fn start_goal(
        &self,
        objective: String,
        token_budget: Option<u64>,
        chat_delegate: Arc<dyn ChatDelegate>,
        goal_delegate: Arc<dyn crate::GoalProgressDelegate>,
    ) -> Result<crate::GoalRunResult, PocketError> {
        let storage = self.goal_storage()?;
        let cancel_token = self.claim_goal_run()?;
        let snapshot = match crate::goals::create(
            storage.clone(),
            self.session_id.clone(),
            objective.clone(),
            token_budget,
        )
        .await
        {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.busy.store(false, Ordering::SeqCst);
                return Err(error);
            }
        };
        let initiating_prompt = match token_budget {
            Some(budget) => format!("/goal --tokens {budget} {objective}"),
            None => format!("/goal {objective}"),
        };
        goal_delegate.on_goal_snapshot(snapshot.clone());
        self.run_goal(
            snapshot,
            Some(initiating_prompt),
            storage,
            cancel_token,
            chat_delegate,
            goal_delegate,
        )
        .await
    }

    /// Resume a previously paused goal without adding another user command.
    pub async fn resume_goal(
        &self,
        chat_delegate: Arc<dyn ChatDelegate>,
        goal_delegate: Arc<dyn crate::GoalProgressDelegate>,
    ) -> Result<crate::GoalRunResult, PocketError> {
        let storage = self.goal_storage()?;
        let cancel_token = self.claim_goal_run()?;
        let snapshot = match crate::goals::resume(storage.clone(), self.session_id.clone()).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.busy.store(false, Ordering::SeqCst);
                return Err(error);
            }
        };
        goal_delegate.on_goal_snapshot(snapshot.clone());
        self.run_goal(
            snapshot,
            None,
            storage,
            cancel_token,
            chat_delegate,
            goal_delegate,
        )
        .await
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
    fn goal_storage(&self) -> Result<crate::sessions::GoalStorage, PocketError> {
        self.persistence
            .as_ref()
            .map(crate::sessions::SessionPersistence::goal_storage)
            .ok_or_else(|| PocketError::Engine {
                message: "goals require a persisted on-device session".to_string(),
            })
    }

    fn claim_goal_run(&self) -> Result<tokio_util::sync::CancellationToken, PocketError> {
        let mut guard = self.cancel.lock();
        if self.busy.swap(true, Ordering::SeqCst) {
            return Err(PocketError::Engine {
                message: "a turn is already running — stop it or wait".to_string(),
            });
        }
        let token = tokio_util::sync::CancellationToken::new();
        *guard = token.clone();
        Ok(token)
    }

    async fn run_goal(
        &self,
        initial_snapshot: crate::GoalSnapshot,
        initiating_prompt: Option<String>,
        goal_storage: crate::sessions::GoalStorage,
        cancel_token: tokio_util::sync::CancellationToken,
        chat_delegate: Arc<dyn ChatDelegate>,
        goal_delegate: Arc<dyn crate::GoalProgressDelegate>,
    ) -> Result<crate::GoalRunResult, PocketError> {
        let result = async {
            let mut durable_messages = self.messages.lock().await;
            if let Some(prompt) = initiating_prompt {
                durable_messages.push(Message::user(prompt));
                self.persist_goal_messages(&durable_messages).await?;
            }
            let mut working_messages = durable_messages.clone();
            let cost_tracker = Arc::new(CostTracker::default());
            let starting_tokens = initial_snapshot.tokens_used;
            let mut goal = claurst_core::Goal {
                id: initial_snapshot.goal_id,
                session_id: initial_snapshot.session_id,
                objective: initial_snapshot.objective,
                status: claurst_core::GoalStatus::Active,
                token_budget: initial_snapshot.token_budget,
                tokens_used: initial_snapshot.tokens_used,
                time_used_secs: initial_snapshot.elapsed_seconds,
                turns_used: initial_snapshot.turns_used,
                created_at_ms: 0,
                updated_at_ms: initial_snapshot.updated_at_ms,
            };

            loop {
                if cancel_token.is_cancelled() {
                    return self
                        .pause_goal_result(goal_storage.clone(), &goal.id, true)
                        .await;
                }
                let turn_started = std::time::Instant::now();
                let (client, query_config, tool_ctx) =
                    self.build_loop_inputs(cost_tracker.clone(), Some(&goal))?;
                let tools = sandbox_goal_tools(
                    &self.config.workspace_dir,
                    self.perms.clone(),
                    Some(chat_delegate.clone()),
                    goal_storage.clone(),
                )?;
                let (event_tx, event_rx) = mpsc::unbounded_channel();
                let forwarder = spawn_event_forwarder(event_rx, chat_delegate.clone(), true);
                let outcome = run_query_loop(
                    &client,
                    &mut working_messages,
                    &tools,
                    &tool_ctx,
                    &query_config,
                    cost_tracker.clone(),
                    Some(event_tx),
                    cancel_token.clone(),
                    None,
                )
                .await;
                let journal = forwarder.await.map_err(PocketError::engine)?;
                durable_messages.extend(journal);
                self.persist_goal_messages(&durable_messages).await?;

                match outcome {
                    QueryOutcome::Cancelled => {
                        return self
                            .pause_goal_result(goal_storage.clone(), &goal.id, true)
                            .await;
                    }
                    QueryOutcome::EndTurn { .. } => {}
                    QueryOutcome::MaxTokens { .. } => {
                        return self
                            .goal_runtime_result(
                                goal_storage.clone(),
                                &goal.id,
                                "model reached its output-token limit".to_string(),
                            )
                            .await;
                    }
                    QueryOutcome::BudgetExceeded {
                        cost_usd,
                        limit_usd,
                    } => {
                        return self
                            .goal_runtime_result(
                                goal_storage.clone(),
                                &goal.id,
                                format!(
                                    "provider budget exceeded: ${cost_usd:.2} of ${limit_usd:.2}"
                                ),
                            )
                            .await;
                    }
                    QueryOutcome::Error(error) => {
                        return self
                            .goal_runtime_result(goal_storage.clone(), &goal.id, error.to_string())
                            .await;
                    }
                }

                let total_tokens = starting_tokens.saturating_add(cost_tracker.total_tokens());
                match crate::goals::continue_after_turn(
                    goal_storage.clone(),
                    self.session_id.clone(),
                    goal.id.clone(),
                    total_tokens,
                    turn_started.elapsed().as_secs(),
                )
                .await?
                {
                    claurst_query::GoalContinuation::Continue { message } => {
                        let snapshot = crate::goals::required_snapshot(
                            goal_storage.clone(),
                            self.session_id.clone(),
                        )
                        .await?;
                        goal_delegate.on_goal_snapshot(snapshot.clone());
                        goal = claurst_core::Goal {
                            id: snapshot.goal_id,
                            session_id: snapshot.session_id,
                            objective: snapshot.objective,
                            status: claurst_core::GoalStatus::Active,
                            token_budget: snapshot.token_budget,
                            tokens_used: snapshot.tokens_used,
                            time_used_secs: snapshot.elapsed_seconds,
                            turns_used: snapshot.turns_used,
                            created_at_ms: 0,
                            updated_at_ms: snapshot.updated_at_ms,
                        };
                        working_messages.push(Message::user(message));
                    }
                    claurst_query::GoalContinuation::Stop { reason } => {
                        let snapshot =
                            crate::goals::required_snapshot(goal_storage, self.session_id.clone())
                                .await?;
                        return Ok(crate::goals::run_result(reason, Some(snapshot)));
                    }
                    claurst_query::GoalContinuation::NoGoal => {
                        return Ok(crate::GoalRunResult {
                            reason: crate::GoalRunStopReason::Cleared,
                            snapshot: None,
                            error_message: None,
                        });
                    }
                }
            }
        }
        .await;
        self.busy.store(false, Ordering::SeqCst);
        result
    }

    async fn persist_goal_messages(&self, messages: &[Message]) -> Result<(), PocketError> {
        let persistence = self
            .persistence
            .as_ref()
            .ok_or_else(|| PocketError::Engine {
                message: "goals require a persisted on-device session".to_string(),
            })?;
        persistence.persist_new(messages).await
    }

    async fn pause_goal_result(
        &self,
        storage: crate::sessions::GoalStorage,
        expected_goal_id: &str,
        cancelled: bool,
    ) -> Result<crate::GoalRunResult, PocketError> {
        match crate::goals::pause_owned(
            storage,
            self.session_id.clone(),
            expected_goal_id.to_string(),
        )
        .await?
        {
            Some(snapshot) => Ok(crate::GoalRunResult {
                reason: if cancelled {
                    crate::GoalRunStopReason::Cancelled
                } else {
                    crate::GoalRunStopReason::Paused
                },
                snapshot: Some(snapshot),
                error_message: None,
            }),
            None => Ok(crate::GoalRunResult {
                reason: crate::GoalRunStopReason::Cleared,
                snapshot: None,
                error_message: None,
            }),
        }
    }

    async fn goal_runtime_result(
        &self,
        storage: crate::sessions::GoalStorage,
        expected_goal_id: &str,
        message: String,
    ) -> Result<crate::GoalRunResult, PocketError> {
        match crate::goals::pause_owned(
            storage,
            self.session_id.clone(),
            expected_goal_id.to_string(),
        )
        .await?
        {
            Some(snapshot) => Ok(crate::GoalRunResult {
                reason: crate::GoalRunStopReason::RuntimeError,
                snapshot: Some(snapshot),
                error_message: Some(message),
            }),
            None => Ok(crate::GoalRunResult {
                reason: crate::GoalRunStopReason::Cleared,
                snapshot: None,
                error_message: None,
            }),
        }
    }

    async fn run_turn(
        &self,
        prompt: Option<String>,
        delegate: Arc<dyn ChatDelegate>,
    ) -> Result<(), PocketError> {
        // Publish busy and its current token under the lock shared with
        // `stop`, then release it before any async setup.
        let cancel_token = {
            let mut guard = self.cancel.lock();
            if self.busy.swap(true, Ordering::SeqCst) {
                None
            } else {
                let token = tokio_util::sync::CancellationToken::new();
                *guard = token.clone();
                Some(token)
            }
        };
        let Some(cancel_token) = cancel_token else {
            let err = PocketError::Engine {
                message: "a turn is already running — stop it or wait".to_string(),
            };
            delegate.on_error(err.to_string());
            return Err(err);
        };
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

            if cancel_token.is_cancelled() {
                return Ok("cancelled");
            }

            #[cfg(test)]
            self.model_tool_loop_invocations
                .fetch_add(1, Ordering::SeqCst);

            let cost_tracker = Arc::new(CostTracker::default());
            let (client, query_config, tool_ctx) =
                self.build_loop_inputs(cost_tracker.clone(), None)?;
            let tools = sandbox_tools(
                &self.config.workspace_dir,
                self.perms.clone(),
                Some(delegate.clone()),
            );

            let (event_tx, event_rx) = mpsc::unbounded_channel();
            let forwarder = spawn_event_forwarder(event_rx, delegate.clone(), false);

            let outcome = run_query_loop(
                &client,
                &mut messages,
                &tools,
                &tool_ctx,
                &query_config,
                cost_tracker,
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
    /// The immutable Pocket platform note, followed by the pinned familiar
    /// identity and the workspace's project context when configured.
    fn append_system_prompt(&self) -> String {
        let mut appended = "You are running inside Coven Pocket on iOS. Only repository file \
             tools are available (no shell, no network tools); every path must \
             stay inside the current workspace."
            .to_string();
        if let Some(familiar) = &self.config.familiar {
            appended.push_str("\n\n");
            match familiar
                .role
                .as_deref()
                .map(str::trim)
                .filter(|role| !role.is_empty())
            {
                Some(role) => appended.push_str(&format!(
                    "[Identity: You are {}, a {}. Respond as {}, not as the underlying tool.]",
                    familiar.display_name, role, familiar.display_name
                )),
                None => appended.push_str(&format!(
                    "[Identity: You are {}. Respond as {}, not as the underlying tool.]",
                    familiar.display_name, familiar.display_name
                )),
            }
        }
        if let Some(context) = &self.config.injected_context {
            appended.push_str("\n\n");
            appended.push_str(context);
        }
        appended
    }

    fn build_loop_inputs(
        &self,
        cost_tracker: Arc<CostTracker>,
        goal: Option<&claurst_core::Goal>,
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
            append_system_prompt: Some(self.append_system_prompt_with_goal(goal)),
            provider_registry: Some(Arc::new(registry)),
            ..QueryConfig::default()
        };
        #[cfg(test)]
        let query_config = if self.config.model == TEST_IMMEDIATE_END_TURN_MODEL {
            QueryConfig {
                max_turns: 0,
                ..query_config
            }
        } else {
            query_config
        };

        let tool_ctx = ToolContext {
            working_dir: workspace.clone(),
            permission_mode: PermissionMode::Default,
            permission_handler: Arc::new(WorkspacePermissionHandler {
                root: workspace.clone(),
            }),
            cost_tracker,
            session_id: self.session_id.clone(),
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

    fn append_system_prompt_with_goal(&self, goal: Option<&claurst_core::Goal>) -> String {
        let mut prompt = self.append_system_prompt();
        if let Some(goal) = goal {
            prompt.push_str("\n\nYou are executing a durable on-device goal. Continue working toward this objective: ");
            prompt.push_str(&goal.objective);
            prompt.push_str(
                ". Use GoalComplete only after a concrete completion audit with evidence.",
            );
        }
        prompt
    }
}

/// Forward query-loop events to the delegate on a dedicated task so slow
/// Swift callbacks never stall tool execution.
fn spawn_event_forwarder(
    mut rx: mpsc::UnboundedReceiver<QueryEvent>,
    delegate: Arc<dyn ChatDelegate>,
    collect_durable_messages: bool,
) -> tokio::task::JoinHandle<Vec<Message>> {
    use claurst_api::streaming::{AnthropicStreamEvent, ContentDelta};
    tokio::spawn(async move {
        let mut journal = Vec::new();
        while let Some(event) = rx.recv().await {
            let Some(event) = record_goal_journal_event(&mut journal, event) else {
                continue;
            };
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
                // `record_goal_journal_event` consumes this first. Keep the
                // arm explicit because Rust cannot infer that refinement.
                QueryEvent::DurableMessage { .. } => {}
                QueryEvent::TurnComplete { .. } | QueryEvent::TokenWarning { .. } => {}
            }
        }
        if collect_durable_messages {
            journal
        } else {
            Vec::new()
        }
    })
}

fn record_goal_journal_event(journal: &mut Vec<Message>, event: QueryEvent) -> Option<QueryEvent> {
    match event {
        QueryEvent::DurableMessage { message } => {
            journal.push(message);
            None
        }
        other => Some(other),
    }
}

/// Create a new chat session. Exposed as a free function so `PocketEngine`
/// stays the single app-facing entry point (see `PocketEngine::start_chat`).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn start_session(
    provider: PocketProvider,
    api_key: String,
    model: String,
    effort: Option<String>,
    workspace_dir: String,
    permission_mode: ChatPermissionMode,
    storage_dir: Option<String>,
    familiar: Option<FamiliarIdentity>,
    inject_context: bool,
) -> Result<Arc<ChatSession>, PocketError> {
    let familiar = familiar.map(normalize_familiar_identity).transpose()?;
    let workspace = resolve_workspace(&workspace_dir)?;
    let session_id = uuid::Uuid::new_v4().to_string();
    let persistence = if let Some(storage_dir) = storage_dir.as_deref() {
        let persistence = crate::sessions::SessionPersistence::create(
            storage_dir,
            session_id.clone(),
            model.clone(),
            familiar.as_ref(),
        )
        .await?;
        Some(persistence)
    } else {
        None
    };
    Ok(Arc::new(ChatSession {
        config: SessionConfig {
            provider,
            api_key,
            model,
            effort,
            familiar,
            injected_context: snapshot_context(inject_context, &workspace),
            workspace_dir: workspace,
        },
        messages: tokio::sync::Mutex::new(Vec::new()),
        cancel: parking_lot::Mutex::new(tokio_util::sync::CancellationToken::new()),
        busy: AtomicBool::new(false),
        perms: Arc::new(PermissionState::new(permission_mode)),
        session_id,
        persistence,
        #[cfg(test)]
        model_tool_loop_invocations: AtomicUsize::new(0),
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
    inject_context: bool,
) -> Result<Arc<ChatSession>, PocketError> {
    let workspace = resolve_workspace(&workspace_dir)?;
    let (persistence, messages, familiar) = crate::sessions::SessionPersistence::resume(
        &storage_dir,
        session_id.clone(),
        model.clone(),
    )
    .await?;
    Ok(Arc::new(ChatSession {
        config: SessionConfig {
            provider,
            api_key,
            model,
            effort,
            familiar,
            injected_context: snapshot_context(inject_context, &workspace),
            workspace_dir: workspace,
        },
        messages: tokio::sync::Mutex::new(messages),
        cancel: parking_lot::Mutex::new(tokio_util::sync::CancellationToken::new()),
        busy: AtomicBool::new(false),
        perms: Arc::new(PermissionState::new(permission_mode)),
        session_id,
        persistence: Some(persistence),
        #[cfg(test)]
        model_tool_loop_invocations: AtomicUsize::new(0),
    }))
}

/// Compose the memory snapshot for a new/resumed session. Empty context
/// (or the toggle being off) means nothing is appended.
fn snapshot_context(inject_context: bool, workspace: &Path) -> Option<String> {
    if !inject_context {
        return None;
    }
    let context = crate::memory::project_context(&workspace.to_string_lossy());
    (!context.text.is_empty()).then_some(context.text)
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

fn sandbox_goal_tools(
    workspace: &Path,
    perms: Arc<PermissionState>,
    delegate: Option<Arc<dyn ChatDelegate>>,
    goal_storage: crate::sessions::GoalStorage,
) -> Result<Vec<Box<dyn Tool>>, PocketError> {
    let mut tools = sandbox_tools(workspace, perms, delegate);
    let inner = claurst_tools::GoalCompleteTool::at_path(goal_storage.path()?);
    tools.push(Box::new(CheckedGoalCompleteTool {
        inner,
        goal_storage,
    }));
    Ok(tools)
}

struct CheckedGoalCompleteTool {
    inner: claurst_tools::PathScopedGoalCompleteTool,
    goal_storage: crate::sessions::GoalStorage,
}

#[async_trait::async_trait]
impl Tool for CheckedGoalCompleteTool {
    fn name(&self) -> &str {
        self.inner.name()
    }

    fn description(&self) -> &str {
        self.inner.description()
    }

    fn permission_level(&self) -> PermissionLevel {
        PermissionLevel::None
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    async fn execute(&self, input: Value, ctx: &ToolContext) -> ToolResult {
        if let Err(error) = self.goal_storage.validate() {
            return ToolResult::error(error.to_string());
        }
        let result = self.inner.execute(input, ctx).await;
        if let Err(error) = self.goal_storage.validate() {
            return ToolResult::error(error.to_string());
        }
        result
    }
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
            &std::env::current_dir().unwrap(),
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

    #[tokio::test]
    async fn session_rejects_relative_workspace() {
        let err = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            "relative/dir".to_string(),
            ChatPermissionMode::Default,
            None,
            None,
            false,
        )
        .await;
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
        let workspace = temp_dir("retry");
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
            None,
            false,
        )
        .await
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

    async fn cancellation_test_session(storage: Option<&Path>) -> (Arc<ChatSession>, PathBuf) {
        let workspace = temp_dir("cancellation-workspace");
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            TEST_IMMEDIATE_END_TURN_MODEL.to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage.map(|path| path.display().to_string()),
            None,
            false,
        )
        .await
        .unwrap();
        (session, workspace)
    }

    async fn wait_until_busy(session: &ChatSession) {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !session.is_busy() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("turn never claimed busy");
    }

    async fn wait_until_messages_locked(session: &ChatSession) {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while session.messages.try_lock().is_ok() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("turn never acquired the messages lock");
    }

    async fn await_turn(
        handle: tokio::task::JoinHandle<Result<(), PocketError>>,
    ) -> Result<(), PocketError> {
        tokio::time::timeout(std::time::Duration::from_secs(10), handle)
            .await
            .expect("turn timed out")
            .expect("turn task panicked")
    }

    fn assert_cancelled_turn(
        session: &ChatSession,
        delegate: &RecordingDelegate,
        expected_loop_invocations: usize,
    ) {
        assert_eq!(
            delegate.done.lock().clone(),
            vec!["cancelled".to_string()],
            "cancelled turns emit exactly one done callback"
        );
        assert!(
            delegate.errors.lock().is_empty(),
            "cancellation must not emit on_error"
        );
        assert!(!session.is_busy(), "terminal cancellation clears busy");
        assert_eq!(
            session.model_tool_loop_invocations.load(Ordering::SeqCst),
            expected_loop_invocations,
            "stopped setup must not enter provider/query/tool loop setup"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_while_waiting_for_messages_cancels_before_loop_setup() {
        let (session, workspace) = cancellation_test_session(None).await;
        let messages = session.messages.lock().await;
        let delegate = Arc::new(RecordingDelegate::default());
        let turn = tokio::spawn({
            let session = session.clone();
            let delegate = delegate.clone();
            async move { session.send("held message".to_string(), delegate).await }
        });

        wait_until_busy(&session).await;
        session.stop();
        drop(messages);

        assert!(await_turn(turn).await.is_ok());
        assert_cancelled_turn(&session, &delegate, 0);
        drop(session);
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_while_persisting_cancels_before_loop_setup() {
        let storage = temp_dir("cancellation-storage");
        let (session, workspace) = cancellation_test_session(Some(&storage)).await;
        let persistence = session.persistence.as_ref().expect("persisted session");
        let persistence_state = persistence.lock_state_for_test().await;
        let delegate = Arc::new(RecordingDelegate::default());
        let turn = tokio::spawn({
            let session = session.clone();
            let delegate = delegate.clone();
            async move { session.send("held persistence".to_string(), delegate).await }
        });

        wait_until_busy(&session).await;
        wait_until_messages_locked(&session).await;
        session.stop();
        drop(persistence_state);

        assert!(await_turn(turn).await.is_ok());
        assert_cancelled_turn(&session, &delegate, 0);
        drop(session);
        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn stop_immediately_after_busy_claim_never_loses_cancellation() {
        let (session, workspace) = cancellation_test_session(None).await;

        for iteration in 0..100 {
            let messages = session.messages.lock().await;
            let start = Arc::new(tokio::sync::Barrier::new(2));
            let delegate = Arc::new(RecordingDelegate::default());
            let turn = tokio::spawn({
                let session = session.clone();
                let start = start.clone();
                let delegate = delegate.clone();
                async move {
                    start.wait().await;
                    session
                        .send(format!("barrier turn {iteration}"), delegate)
                        .await
                }
            });
            let stopper = tokio::spawn({
                let session = session.clone();
                async move {
                    start.wait().await;
                    wait_until_busy(&session).await;
                    session.stop();
                }
            });

            tokio::time::timeout(std::time::Duration::from_secs(5), stopper)
                .await
                .expect("stopper timed out")
                .expect("stopper task panicked");
            drop(messages);

            assert!(await_turn(turn).await.is_ok(), "iteration {iteration}");
            assert_cancelled_turn(&session, &delegate, 0);
        }

        drop(session);
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_busy_send_does_not_replace_first_turn_token() {
        let (session, workspace) = cancellation_test_session(None).await;
        let messages = session.messages.lock().await;
        let first_delegate = Arc::new(RecordingDelegate::default());
        let first_turn = tokio::spawn({
            let session = session.clone();
            let delegate = first_delegate.clone();
            async move { session.send("first".to_string(), delegate).await }
        });

        wait_until_busy(&session).await;
        let active_before = session.cancel.lock().clone();
        let second_delegate = Arc::new(RecordingDelegate::default());
        let second_result = session
            .send("second".to_string(), second_delegate.clone())
            .await;
        let active_after = session.cancel.lock().clone();

        assert!(second_result.is_err());
        assert_eq!(
            active_before, active_after,
            "a rejected busy send must not replace the active token"
        );
        assert!(second_delegate.done.lock().is_empty());
        assert_eq!(second_delegate.errors.lock().len(), 1);

        session.stop();
        drop(messages);

        assert!(await_turn(first_turn).await.is_ok());
        assert_cancelled_turn(&session, &first_delegate, 0);
        drop(session);
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn turn_after_setup_cancellation_uses_fresh_uncancelled_token() {
        let (session, workspace) = cancellation_test_session(None).await;
        let messages = session.messages.lock().await;
        let cancelled_delegate = Arc::new(RecordingDelegate::default());
        let cancelled_turn = tokio::spawn({
            let session = session.clone();
            let delegate = cancelled_delegate.clone();
            async move { session.send("cancel me".to_string(), delegate).await }
        });

        wait_until_busy(&session).await;
        session.stop();
        drop(messages);
        assert!(await_turn(cancelled_turn).await.is_ok());
        assert_cancelled_turn(&session, &cancelled_delegate, 0);
        let cancelled_token = session.cancel.lock().clone();
        assert!(cancelled_token.is_cancelled());

        let next_delegate = Arc::new(RecordingDelegate::default());
        let next_result = session
            .send("next turn".to_string(), next_delegate.clone())
            .await;
        assert!(matches!(next_result, Err(PocketError::Provider { .. })));
        let next_token = session.cancel.lock().clone();

        assert_ne!(cancelled_token, next_token);
        assert!(!next_token.is_cancelled());
        assert!(next_delegate.done.lock().is_empty());
        assert_eq!(next_delegate.errors.lock().len(), 1);
        assert!(!session.is_busy());
        assert_eq!(
            session.model_tool_loop_invocations.load(Ordering::SeqCst),
            1
        );

        drop(session);
        std::fs::remove_dir_all(workspace).unwrap();
    }

    // -- memory injection ---------------------------------------------------

    fn test_familiar(role: Option<&str>) -> crate::remote::FamiliarIdentity {
        crate::remote::FamiliarIdentity {
            id: "familiar-1".to_string(),
            display_name: "Morgana".to_string(),
            emoji: Some("moon".to_string()),
            role: role.map(str::to_string),
        }
    }

    #[tokio::test]
    async fn familiar_preamble_uses_exact_role_and_no_role_forms() {
        let workspace = std::env::current_dir().unwrap();
        let with_role = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
            Some(test_familiar(Some("repository guide"))),
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            with_role.append_system_prompt(),
            "You are running inside Coven Pocket on iOS. Only repository file tools are \
             available (no shell, no network tools); every path must stay inside the current \
             workspace.\n\n[Identity: You are Morgana, a repository guide. Respond as Morgana, \
             not as the underlying tool.]"
        );

        for role in [None, Some("   ")] {
            let without_role = start_session(
                PocketProvider::Anthropic,
                "key".to_string(),
                "model".to_string(),
                None,
                workspace.display().to_string(),
                ChatPermissionMode::Default,
                None,
                Some(test_familiar(role)),
                false,
            )
            .await
            .unwrap();
            assert_eq!(
                without_role.append_system_prompt(),
                "You are running inside Coven Pocket on iOS. Only repository file tools are \
                 available (no shell, no network tools); every path must stay inside the current \
                 workspace.\n\n[Identity: You are Morgana. Respond as Morgana, not as the \
                 underlying tool.]"
            );
        }
    }

    #[tokio::test]
    async fn start_session_normalizes_arbitrary_familiar_input() {
        let workspace = temp_dir("ws-normalize-familiar");
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
            Some(crate::remote::FamiliarIdentity {
                id: " familiar-1 ".to_string(),
                display_name: " Morgana ".to_string(),
                emoji: Some(" moon ".to_string()),
                role: Some(" repository guide ".to_string()),
            }),
            false,
        )
        .await
        .unwrap();

        assert_eq!(
            session.config.familiar,
            Some(crate::remote::FamiliarIdentity {
                id: "familiar-1".to_string(),
                display_name: "Morgana".to_string(),
                emoji: Some("moon".to_string()),
                role: Some("repository guide".to_string()),
            })
        );
        assert!(session
            .append_system_prompt()
            .contains("[Identity: You are Morgana, a repository guide."));

        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn start_session_rejects_oversized_familiar_before_persistence_or_prompt() {
        let storage = temp_dir("store-oversized-familiar");
        let workspace = temp_dir("ws-oversized-familiar");
        let mut identity = test_familiar(Some("repository guide"));
        identity.role = Some("r".repeat(1025));

        let err = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            Some(storage.display().to_string()),
            Some(identity),
            false,
        )
        .await
        .err()
        .expect("oversized familiar must be rejected before creating a session");
        let message = err.to_string();
        assert!(message.contains("familiar role"), "got: {message}");
        assert!(message.contains("1024-byte limit"), "got: {message}");
        assert!(!storage.join("metadata").exists());
        assert!(!storage.join(".session-lifecycle").exists());

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn familiar_keeps_plan_mode_platform_note_and_memory_order() {
        let guard = crate::memory::tests::setup("chat-familiar");
        std::fs::write(guard.workspace.join("AGENTS.md"), "Pinned project memory.").unwrap();
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            guard.workspace.display().to_string(),
            ChatPermissionMode::Plan,
            None,
            Some(test_familiar(Some("planner"))),
            true,
        )
        .await
        .unwrap();

        let prompt = session.append_system_prompt();
        let platform = prompt
            .find("You are running inside Coven Pocket on iOS.")
            .unwrap();
        let familiar = prompt
            .find("[Identity: You are Morgana, a planner.")
            .unwrap();
        let memory = prompt.find("Pinned project memory.").unwrap();
        assert!(platform < familiar && familiar < memory);
        assert_eq!(session.permission_mode(), ChatPermissionMode::Plan);
    }

    /// The workspace AGENTS.md must reach the model iff the toggle is on.
    #[tokio::test]
    async fn inject_context_gates_agents_md_in_system_prompt() {
        let guard = crate::memory::tests::setup("chat-inject");
        let workspace = guard.workspace.clone();
        std::fs::write(
            workspace.join("AGENTS.md"),
            "Pocket rule: always answer in haiku.",
        )
        .unwrap();

        let with_context = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
            None,
            true,
        )
        .await
        .unwrap();
        assert!(
            with_context
                .append_system_prompt()
                .contains("always answer in haiku"),
            "inject_context=true must append workspace AGENTS.md"
        );

        let without_context = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            None,
            None,
            false,
        )
        .await
        .unwrap();
        assert!(
            !without_context
                .append_system_prompt()
                .contains("always answer in haiku"),
            "inject_context=false must leave the system prompt untouched"
        );
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
            root: std::env::current_dir().unwrap(),
            perms: perms.clone(),
            delegate,
        };
        (tool, ran, perms)
    }

    fn write_input() -> Value {
        let path = std::env::current_dir().unwrap().join("gate-test.txt");
        serde_json::json!({ "file_path": path, "content": "hello" })
    }

    async fn test_ctx() -> ToolContext {
        // Only fields the stub path touches matter; reuse the session builder
        // for a fully-populated context.
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "model".to_string(),
            None,
            std::env::current_dir().unwrap().display().to_string(),
            ChatPermissionMode::Default,
            None,
            None,
            false,
        )
        .await
        .unwrap();
        let (_client, _config, ctx) = session
            .build_loop_inputs(Arc::new(CostTracker::default()), None)
            .unwrap();
        ctx
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn plan_mode_refuses_writes_without_prompting() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Allow));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Plan, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx().await).await;

        assert!(result.is_error);
        assert!(!ran.load(Ordering::SeqCst), "plan mode must not execute");
        assert!(delegate.prompts.lock().is_empty(), "plan mode never asks");
    }

    #[test]
    fn goal_journal_records_only_durable_query_messages() {
        let mut journal = Vec::new();
        record_goal_journal_event(
            &mut journal,
            QueryEvent::DurableMessage {
                message: Message::assistant("working"),
            },
        );
        assert_eq!(journal.len(), 1);
        assert_eq!(journal[0].get_all_text(), "working");
    }

    #[test]
    fn goal_journal_is_independent_of_compacted_working_history() {
        let mut journal = vec![Message::assistant("durable output")];
        let working = [Message::user("compacted summary")];
        assert_eq!(journal.remove(0).get_all_text(), "durable output");
        assert_eq!(working[0].get_all_text(), "compacted summary");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn accept_edits_runs_writes_without_prompting() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Deny));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::AcceptEdits, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx().await).await;

        assert!(!result.is_error);
        assert!(ran.load(Ordering::SeqCst));
        assert!(delegate.prompts.lock().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn default_mode_denial_blocks_execution() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Deny));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Default, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx().await).await;

        assert!(result.is_error);
        assert!(!ran.load(Ordering::SeqCst));
        assert_eq!(delegate.prompts.lock().len(), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn default_mode_approval_executes() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Allow));
        let (tool, ran, _) = gated_stub(ChatPermissionMode::Default, Some(delegate.clone()));

        let result = tool.execute(write_input(), &test_ctx().await).await;

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
        let ctx = test_ctx().await;

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

        let result = tool.execute(write_input(), &test_ctx().await).await;

        assert!(result.is_error);
        assert!(!ran.load(Ordering::SeqCst));
        assert_eq!(delegate.prompts.lock().len(), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn read_only_tools_bypass_the_gate() {
        let delegate = Arc::new(RecordingDelegate::answering(ChatPermissionDecision::Deny));
        let perms = Arc::new(PermissionState::new(ChatPermissionMode::Default));
        let workspace = temp_dir("read-gate").canonicalize().unwrap();
        let tools = sandbox_tools(&workspace, perms, Some(delegate.clone()));
        let read = tools
            .iter()
            .find(|t| t.name() == "Read")
            .expect("Read tool in sandbox");
        let target = workspace.join("gate-read-test.txt");
        std::fs::write(&target, "content").unwrap();

        let result = read
            .execute(
                serde_json::json!({ "file_path": target }),
                &test_ctx().await,
            )
            .await;

        assert!(!result.is_error);
        assert!(delegate.prompts.lock().is_empty());
        std::fs::remove_dir_all(workspace).unwrap();
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
        let dir = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("chat-tests")
            .join(format!("{label}-{}", uuid::Uuid::new_v4()));
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
            None,
            false,
        )
        .await
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
    async fn persisted_new_session_saves_familiar_before_returning() {
        let storage = temp_dir("store-familiar");
        let workspace = temp_dir("ws-familiar");
        let identity = test_familiar(Some("repository guide"));
        let session = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Plan,
            Some(storage.display().to_string()),
            Some(identity.clone()),
            false,
        )
        .await
        .unwrap();

        assert_eq!(
            crate::sessions::load_familiar_metadata(
                &storage.display().to_string(),
                &session.session_id()
            )
            .unwrap(),
            Some(identity)
        );

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn persisted_session_shows_up_in_list_with_derived_title() {
        let storage = temp_dir("store");
        let workspace = temp_dir("ws");

        let session = persisted_session(&storage, &workspace).await;
        let listed = crate::sessions::list_sessions(&storage.display().to_string())
            .await
            .unwrap();
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
        let session_id = original.session_id();
        drop(original);
        let resumed = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str.clone(),
            session_id.clone(),
            false,
        )
        .await
        .unwrap();

        assert_eq!(resumed.session_id(), session_id);
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
        let listed = crate::sessions::list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].message_count, 3);

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[tokio::test]
    async fn newly_started_session_blocks_resume_until_all_arcs_drop() {
        let storage = temp_dir("store-writer-lease");
        let workspace = temp_dir("ws-writer-lease");
        let storage_str = storage.display().to_string();
        let original = persisted_session(&storage, &workspace).await;
        let surviving_clone = original.clone();
        let session_id = original.session_id();

        let first_error = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str.clone(),
            session_id.clone(),
            false,
        )
        .await
        .err()
        .expect("a newly started session must retain its writer lease");
        assert!(first_error
            .to_string()
            .contains(&format!("session {session_id} is already open for writing")));

        drop(original);
        let clone_error = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str.clone(),
            session_id.clone(),
            false,
        )
        .await
        .err()
        .expect("a surviving ChatSession Arc must retain the writer lease");
        assert!(clone_error
            .to_string()
            .contains(&format!("session {session_id} is already open for writing")));

        drop(surviving_clone);
        let resumed = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str,
            session_id.clone(),
            false,
        )
        .await
        .unwrap();
        assert_eq!(resumed.session_id(), session_id);

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[tokio::test]
    async fn resume_loads_the_stored_familiar_snapshot() {
        let storage = temp_dir("store-resume-familiar");
        let workspace = temp_dir("ws-resume-familiar");
        let storage_str = storage.display().to_string();
        let identity = test_familiar(Some("repository guide"));
        let original = start_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Plan,
            Some(storage_str.clone()),
            Some(identity.clone()),
            false,
        )
        .await
        .unwrap();
        let delegate: Arc<dyn ChatDelegate> = Arc::new(RecordingDelegate::default());
        {
            let mut messages = original.messages.lock().await;
            messages.push(Message::user("remember me"));
            original.persist_new(&messages, &delegate).await;
        }
        let session_id = original.session_id();
        drop(original);

        let resumed = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Plan,
            storage_str,
            session_id,
            false,
        )
        .await
        .unwrap();

        assert_eq!(resumed.config.familiar, Some(identity));
        assert!(resumed
            .append_system_prompt()
            .contains("[Identity: You are Morgana, a repository guide."));
        assert_eq!(resumed.permission_mode(), ChatPermissionMode::Plan);

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn resume_fails_visibly_for_malformed_familiar_metadata() {
        let storage = temp_dir("store-resume-malformed");
        let workspace = temp_dir("ws-resume-malformed");
        let storage_str = storage.display().to_string();
        let original = persisted_session(&storage, &workspace).await;
        let session_id = original.session_id();
        let metadata = storage
            .join("metadata")
            .join(format!("{session_id}.familiar.json"));
        std::fs::create_dir_all(metadata.parent().unwrap()).unwrap();
        std::fs::write(metadata, b"not-json").unwrap();
        drop(original);

        let err = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Plan,
            storage_str,
            session_id,
            false,
        )
        .await
        .err()
        .expect("malformed familiar metadata must fail resume");
        assert!(err.to_string().contains("cannot parse familiar metadata"));

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn resume_rejects_oversized_familiar_metadata_before_reading_it() {
        let storage = temp_dir("store-resume-oversized-familiar");
        let workspace = temp_dir("ws-resume-oversized-familiar");
        let storage_str = storage.display().to_string();
        let original = persisted_session(&storage, &workspace).await;
        let session_id = original.session_id();
        let metadata = storage
            .join("metadata")
            .join(format!("{session_id}.familiar.json"));
        std::fs::create_dir_all(metadata.parent().unwrap()).unwrap();
        let file = std::fs::File::create(&metadata).unwrap();
        file.set_len(crate::sessions::MAX_FAMILIAR_IDENTITY_SIDECAR_BYTES + 1)
            .unwrap();
        drop(file);
        drop(original);

        let err = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Plan,
            storage_str,
            session_id,
            false,
        )
        .await
        .err()
        .expect("oversized familiar metadata must fail resume");
        let message = err.to_string();
        assert!(message.contains("familiar metadata"), "got: {message}");
        assert!(message.contains("10240-byte limit"), "got: {message}");
        assert_eq!(
            std::fs::symlink_metadata(metadata).unwrap().len(),
            crate::sessions::MAX_FAMILIAR_IDENTITY_SIDECAR_BYTES + 1
        );

        std::fs::remove_dir_all(storage).unwrap();
        std::fs::remove_dir_all(workspace).unwrap();
    }

    #[tokio::test]
    async fn resume_unknown_session_errors() {
        let storage = temp_dir("store");
        let err = resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            std::env::current_dir().unwrap().display().to_string(),
            ChatPermissionMode::Default,
            storage.display().to_string(),
            uuid::Uuid::new_v4().to_string(),
            false,
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

        let listed = crate::sessions::list_sessions(&storage_str).await.unwrap();
        assert_eq!(listed.len(), 2);
        let fork_row = listed
            .iter()
            .find(|s| s.session_id == fork_id)
            .expect("fork listed");
        assert_eq!(fork_row.title, "hello world");
        assert_eq!(fork_row.model, "claude-test");
        assert_eq!(fork_row.message_count, 2);

        // Deleting the original leaves the fork intact and resumable.
        crate::sessions::delete_session(&storage_str, &original.session_id())
            .await
            .unwrap();
        let listed = crate::sessions::list_sessions(&storage_str).await.unwrap();
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
            false,
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
        crate::sessions::delete_session(&storage_str, &session.session_id())
            .await
            .unwrap();
        assert!(crate::sessions::list_sessions(&storage_str)
            .await
            .unwrap()
            .is_empty());
        let err = match resume_session(
            PocketProvider::Anthropic,
            "key".to_string(),
            "claude-test".to_string(),
            None,
            workspace.display().to_string(),
            ChatPermissionMode::Default,
            storage_str,
            session.session_id(),
            false,
        )
        .await
        {
            Ok(_) => panic!("deleted session must not resume"),
            Err(err) => err,
        };
        assert!(err.to_string().contains("was deleted"));

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
            None,
            false,
        )
        .await
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
                .await
                .unwrap()
                .is_empty()
        );

        let _ = std::fs::remove_dir_all(&storage);
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
