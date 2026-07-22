//! coven-pocket-ffi: the UniFFI surface Coven Pocket's Swift app talks to.
//!
//! This crate is intentionally thin. Engine behavior (providers, streaming,
//! sessions) lives in the coven-code crates (`claurst-core`, `claurst-api`);
//! this layer only adapts types across the FFI boundary.

use std::sync::Arc;

use claurst_api::client::ClientConfig;
use claurst_api::provider::LlmProvider;
use claurst_api::provider_types::{ProviderRequest, StreamEvent, ThinkingConfig};
use claurst_api::providers::{AnthropicProvider, CodexProvider};
use claurst_api::AnthropicClient;
use claurst_core::effort::{model_uses_adaptive_thinking, EffortLevel};
use claurst_core::types::Message;
use futures::StreamExt;

mod chat;
mod codex_auth;
mod daemon;
mod git;
mod remote;
mod sessions;
mod share;

pub use chat::{
    ChatDelegate, ChatMessage, ChatPermissionDecision, ChatPermissionMode, ChatPermissionRequest,
    ChatPermissionResponder, ChatSession,
};
pub use codex_auth::{CodexAccount, CodexAuthDelegate};
pub use daemon::{DaemonHandshake, DaemonIdentity, DaemonProbeState};
pub use git::{GitCredentials, GitWorkspaceSummary};
pub use remote::{RemoteEvent, RemoteEventBatch, RemoteSession};
pub use sessions::ChatSessionSummary;
pub use share::{RedactionFinding, RedactionResult};

uniffi::setup_scaffolding!();

/// Errors surfaced to Swift.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PocketError {
    #[error("engine error: {message}")]
    Engine { message: String },
    #[error("provider error: {message}")]
    Provider { message: String },
}

impl PocketError {
    fn engine(err: impl std::fmt::Display) -> Self {
        Self::Engine {
            message: err.to_string(),
        }
    }
}

/// Convert an FFI timeout in milliseconds into a [`std::time::Duration`].
fn millis(timeout_ms: u32) -> std::time::Duration {
    std::time::Duration::from_millis(u64::from(timeout_ms))
}

/// Run blocking work (libgit2, filesystem) on the tokio blocking pool so
/// async FFI methods never stall an executor thread.
async fn run_blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, PocketError> + Send + 'static,
) -> Result<T, PocketError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(PocketError::engine)?
}

/// A model available to the active provider.
#[derive(uniffi::Record)]
pub struct PocketModel {
    pub id: String,
    pub provider_id: String,
    pub name: String,
    pub context_window: u32,
    pub max_output_tokens: u32,
}

/// Inference providers Coven Pocket can talk to.
#[derive(uniffi::Enum)]
pub enum PocketProvider {
    /// Anthropic Messages API, authenticated with an API key.
    Anthropic,
    /// OpenAI Codex (ChatGPT subscription), authenticated via OAuth.
    Codex,
}

/// Streaming callbacks implemented on the Swift side.
///
/// Callbacks arrive on Rust worker threads; the Swift implementation is
/// responsible for hopping to the main actor before touching UI.
#[uniffi::export(with_foreign)]
pub trait StreamDelegate: Send + Sync {
    fn on_text(&self, text: String);
    fn on_thinking(&self, text: String);
    fn on_done(&self, stop_reason: String);
    fn on_error(&self, message: String);
}

fn anthropic_provider(api_key: &str) -> Result<AnthropicProvider, PocketError> {
    let config = ClientConfig {
        api_key: api_key.to_string(),
        ..ClientConfig::default()
    };
    let client = AnthropicClient::new(config).map_err(PocketError::engine)?;
    Ok(AnthropicProvider::new(Arc::new(client)))
}

fn codex_provider() -> Result<CodexProvider, PocketError> {
    CodexProvider::from_stored().ok_or_else(|| PocketError::Provider {
        message: "not signed in to Codex — connect a ChatGPT account first".to_string(),
    })
}

/// Request knobs derived from a named effort level.
struct EffortParams {
    thinking: Option<ThinkingConfig>,
    temperature: Option<f64>,
    max_tokens: u32,
}

/// Map an effort level onto Anthropic request parameters.
///
/// Mirrors coven-code's `EffortLevel` semantics: Medium/High/Max enable
/// extended thinking with the engine's budget table, Low pins temperature
/// to 0.0 with no thinking. Models with adaptive thinking (Opus 4.7+,
/// Fable 5) reject manual budgets, so they get `thinking: adaptive` and the
/// model decides its own depth. `max_tokens` grows above the thinking
/// budget so visible output is never squeezed out by reasoning tokens.
fn effort_params(model: &str, effort: Option<&str>, base_max_tokens: u32) -> EffortParams {
    let mut params = EffortParams {
        thinking: None,
        temperature: None,
        max_tokens: base_max_tokens,
    };
    let Some(level) = effort.and_then(EffortLevel::parse) else {
        return params;
    };

    if model_uses_adaptive_thinking(model) {
        params.thinking = Some(ThinkingConfig::adaptive());
    } else if let Some(budget) = level.thinking_budget_tokens() {
        params.thinking = Some(ThinkingConfig::enabled(budget));
        params.max_tokens = budget + base_max_tokens;
    }
    params.temperature = level.temperature().map(f64::from);
    params
}

fn pocket_model(m: claurst_api::provider::ModelInfo) -> PocketModel {
    PocketModel {
        id: m.id.to_string(),
        provider_id: m.provider_id.to_string(),
        name: m.name,
        context_window: m.context_window,
        max_output_tokens: m.max_output_tokens,
    }
}

/// The engine handle held by the app for its whole lifetime.
#[derive(uniffi::Object)]
pub struct PocketEngine;

#[uniffi::export(async_runtime = "tokio")]
impl PocketEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self)
    }

    /// Version of the linked coven-code engine crates.
    pub fn engine_version(&self) -> String {
        claurst_core::constants::APP_VERSION.to_string()
    }

    /// The engine's default model id.
    pub fn default_model(&self) -> String {
        claurst_core::constants::DEFAULT_MODEL.to_string()
    }

    /// List models available through the Anthropic provider.
    pub async fn list_models(&self, api_key: String) -> Result<Vec<PocketModel>, PocketError> {
        let provider = anthropic_provider(&api_key)?;
        let models = provider.list_models().await.map_err(PocketError::engine)?;
        Ok(models.into_iter().map(pocket_model).collect())
    }

    /// List models available through the Codex provider.
    ///
    /// Requires a signed-in Codex account; the catalog itself is static.
    pub async fn list_codex_models(&self) -> Result<Vec<PocketModel>, PocketError> {
        let provider = codex_provider()?;
        let models = provider.list_models().await.map_err(PocketError::engine)?;
        Ok(models.into_iter().map(pocket_model).collect())
    }

    /// The engine's default Codex model id.
    pub fn default_codex_model(&self) -> String {
        claurst_core::codex_oauth::DEFAULT_CODEX_MODEL.to_string()
    }

    /// Interactive Codex (ChatGPT) sign-in.
    ///
    /// Binds the localhost callback listener, hands the auth URL to
    /// `delegate` for browser presentation, and resolves once the user
    /// completes the flow. Tokens persist in the app sandbox through the
    /// engine's profile registry.
    pub async fn codex_login(
        &self,
        delegate: Arc<dyn CodexAuthDelegate>,
    ) -> Result<CodexAccount, PocketError> {
        codex_auth::login(delegate).await
    }

    /// The signed-in Codex account, if any.
    pub fn codex_account(&self) -> Option<CodexAccount> {
        codex_auth::current_account()
    }

    /// Sign out of Codex, clearing stored tokens.
    pub fn codex_logout(&self) -> Result<(), PocketError> {
        codex_auth::logout()
    }

    /// Start a multi-turn agentic chat session bound to `workspace_dir`.
    ///
    /// The session runs the engine's query loop with the sandbox-safe
    /// file-tool profile (Read/Grep/Glob/Edit/Write/ApplyPatch/BatchEdit/
    /// NotebookEdit); process, network, and task tools are excluded at
    /// registry build time, and every tool call is contained to the
    /// workspace directory. `workspace_dir` must be an absolute path inside
    /// the app sandbox; it is created if missing. `permission_mode` gates
    /// write tools (see [`ChatPermissionMode`]) and can be changed later via
    /// [`ChatSession::set_permission_mode`].
    ///
    /// With a `storage_dir` (absolute, created if missing) the conversation
    /// persists on device and shows up in [`Self::list_chat_sessions`];
    /// `None` keeps the session in memory only.
    #[allow(clippy::too_many_arguments)]
    pub fn start_chat(
        &self,
        provider: PocketProvider,
        api_key: String,
        model: String,
        effort: Option<String>,
        workspace_dir: String,
        permission_mode: ChatPermissionMode,
        storage_dir: Option<String>,
    ) -> Result<Arc<ChatSession>, PocketError> {
        chat::start_session(
            provider,
            api_key,
            model,
            effort,
            workspace_dir,
            permission_mode,
            storage_dir,
        )
    }

    /// Resume a stored session at its head: the full transcript is restored
    /// and new turns append to the same record. Provider settings are the
    /// caller's current ones, not necessarily those the session started with.
    #[allow(clippy::too_many_arguments)]
    pub async fn resume_chat(
        &self,
        provider: PocketProvider,
        api_key: String,
        model: String,
        effort: Option<String>,
        workspace_dir: String,
        permission_mode: ChatPermissionMode,
        storage_dir: String,
        session_id: String,
    ) -> Result<Arc<ChatSession>, PocketError> {
        chat::resume_session(
            provider,
            api_key,
            model,
            effort,
            workspace_dir,
            permission_mode,
            storage_dir,
            session_id,
        )
        .await
    }

    /// Stored sessions, newest first. Async so the SQLite read stays off the
    /// caller's thread (UI thread on iOS).
    pub async fn list_chat_sessions(
        &self,
        storage_dir: String,
    ) -> Result<Vec<ChatSessionSummary>, PocketError> {
        sessions::list_sessions(&storage_dir)
    }

    /// Delete a stored session and its transcript.
    pub async fn delete_chat_session(
        &self,
        storage_dir: String,
        session_id: String,
    ) -> Result<(), PocketError> {
        sessions::delete_session(&storage_dir, &session_id)
    }

    /// Copy a stored session at its head under a new id, returning that id.
    pub async fn fork_chat_session(
        &self,
        storage_dir: String,
        session_id: String,
    ) -> Result<String, PocketError> {
        sessions::fork_session(&storage_dir, &session_id).await
    }

    // MARK: git workspaces
    //
    // libgit2 calls are blocking (disk and network), so every method here
    // hops to the tokio blocking pool. `workspaces_dir` is an app-sandbox
    // directory holding one folder per cloned repository; summaries carry
    // the absolute workspace path to hand to `start_chat`.

    /// Clone a repository. `name` defaults to the repo name in the URL.
    pub async fn git_clone(
        &self,
        workspaces_dir: String,
        url: String,
        name: Option<String>,
        credentials: GitCredentials,
    ) -> Result<GitWorkspaceSummary, PocketError> {
        run_blocking(move || git::clone(&workspaces_dir, &url, name, &credentials)).await
    }

    /// All cloned workspaces, sorted by name.
    pub async fn git_list_workspaces(
        &self,
        workspaces_dir: String,
    ) -> Result<Vec<GitWorkspaceSummary>, PocketError> {
        run_blocking(move || git::list(&workspaces_dir)).await
    }

    /// Remove a workspace and everything in it.
    pub async fn git_delete_workspace(
        &self,
        workspaces_dir: String,
        name: String,
    ) -> Result<(), PocketError> {
        run_blocking(move || git::delete(&workspaces_dir, &name)).await
    }

    /// Fetch origin and fast-forward the current branch. Errors when the
    /// histories have diverged instead of attempting a merge.
    pub async fn git_pull(
        &self,
        workspaces_dir: String,
        name: String,
        credentials: GitCredentials,
    ) -> Result<GitWorkspaceSummary, PocketError> {
        run_blocking(move || git::pull(&workspaces_dir, &name, &credentials)).await
    }

    /// Stage all changes and commit them, returning the short commit id.
    pub async fn git_commit_all(
        &self,
        workspaces_dir: String,
        name: String,
        message: String,
        author_name: String,
        author_email: String,
    ) -> Result<String, PocketError> {
        run_blocking(move || {
            git::commit_all(
                &workspaces_dir,
                &name,
                &message,
                &author_name,
                &author_email,
            )
        })
        .await
    }

    /// Push the current branch to origin (sets upstream on first push).
    pub async fn git_push(
        &self,
        workspaces_dir: String,
        name: String,
        credentials: GitCredentials,
    ) -> Result<GitWorkspaceSummary, PocketError> {
        run_blocking(move || git::push(&workspaces_dir, &name, &credentials)).await
    }

    /// Local branch names, current branch first.
    pub async fn git_branches(
        &self,
        workspaces_dir: String,
        name: String,
    ) -> Result<Vec<String>, PocketError> {
        run_blocking(move || git::branches(&workspaces_dir, &name)).await
    }

    /// Switch branches (optionally creating one off HEAD). Existing remote
    /// branches get a local tracking branch. Dirty worktrees are refused.
    pub async fn git_checkout(
        &self,
        workspaces_dir: String,
        name: String,
        branch: String,
        create: bool,
    ) -> Result<GitWorkspaceSummary, PocketError> {
        run_blocking(move || git::checkout(&workspaces_dir, &name, &branch, create)).await
    }

    /// Probe a Coven daemon's `/health` endpoint at `host:port` (reached via
    /// the user's Tailscale network or SSH tunnel; the daemon's TCP listener
    /// itself stays loopback on its host). Never throws — every outcome is a
    /// [`DaemonProbeState`] the UI can render directly.
    pub async fn probe_daemon(&self, host: String, port: u16, timeout_ms: u32) -> DaemonProbeState {
        daemon::probe(
            &host,
            port,
            std::time::Duration::from_millis(u64::from(timeout_ms)),
        )
        .await
    }

    /// Perform the mandatory `coven.daemon.v1` handshake against
    /// `host:port`: fetch `/api/v1/health` and accept only a daemon that
    /// speaks the required contract. Pairing and all session traffic gate
    /// on a [`DaemonHandshake::Compatible`] result. Never throws.
    pub async fn handshake_daemon(
        &self,
        host: String,
        port: u16,
        timeout_ms: u32,
    ) -> DaemonHandshake {
        daemon::handshake(
            &host,
            port,
            std::time::Duration::from_millis(u64::from(timeout_ms)),
        )
        .await
    }

    /// List sessions on the paired daemon. Callers gate on a verified
    /// pairing first; this is plain transport.
    pub async fn remote_sessions(
        &self,
        host: String,
        port: u16,
        timeout_ms: u32,
    ) -> Result<Vec<RemoteSession>, PocketError> {
        remote::sessions(&host, port, millis(timeout_ms)).await
    }

    /// Read one page of a remote session's events after `after_seq`.
    pub async fn remote_events(
        &self,
        host: String,
        port: u16,
        session_id: String,
        after_seq: i64,
        limit: u32,
        timeout_ms: u32,
    ) -> Result<RemoteEventBatch, PocketError> {
        remote::events(
            &host,
            port,
            &session_id,
            after_seq,
            limit,
            millis(timeout_ms),
        )
        .await
    }

    /// Forward input (a chat turn or an approval keystroke) to a live
    /// remote session.
    pub async fn remote_send_input(
        &self,
        host: String,
        port: u16,
        session_id: String,
        data: String,
        timeout_ms: u32,
    ) -> Result<(), PocketError> {
        remote::send_input(&host, port, &session_id, &data, millis(timeout_ms)).await
    }

    /// Kill a live remote session.
    pub async fn remote_kill(
        &self,
        host: String,
        port: u16,
        session_id: String,
        timeout_ms: u32,
    ) -> Result<(), PocketError> {
        remote::kill(&host, port, &session_id, millis(timeout_ms)).await
    }

    /// Scrub credential-shaped content from a transcript before sharing.
    /// Runs on the blocking pool: transcripts can be large and the pass is
    /// regex-heavy.
    pub async fn redact_secrets(&self, text: String) -> Result<RedactionResult, PocketError> {
        run_blocking(move || share::redact_secrets(&text).map_err(PocketError::engine)).await
    }

    /// Stream a single-turn completion, forwarding deltas to `delegate`.
    ///
    /// `effort` accepts `"low" | "medium" | "high" | "max"` and maps onto
    /// Anthropic extended thinking (see [`effort_params`]). The Codex
    /// Responses adapter does not encode a reasoning-effort control at the
    /// current engine pin, so effort is a no-op there. `api_key` is only
    /// used for Anthropic; Codex authenticates from stored OAuth tokens.
    ///
    /// Resolves once the stream finishes; terminal state is reported through
    /// `on_done` / `on_error` as well so fire-and-forget callers stay correct.
    pub async fn stream_prompt(
        &self,
        provider: PocketProvider,
        api_key: String,
        model: String,
        prompt: String,
        effort: Option<String>,
        delegate: Arc<dyn StreamDelegate>,
    ) -> Result<(), PocketError> {
        let effort = effort_params(&model, effort.as_deref(), 4096);
        let provider: Box<dyn LlmProvider> = match provider {
            PocketProvider::Anthropic => Box::new(anthropic_provider(&api_key)?),
            PocketProvider::Codex => Box::new(codex_provider()?),
        };
        let request = ProviderRequest {
            model,
            messages: vec![Message::user(prompt)],
            system_prompt: None,
            tools: Vec::new(),
            max_tokens: effort.max_tokens,
            temperature: effort.temperature,
            top_p: None,
            top_k: None,
            stop_sequences: Vec::new(),
            thinking: effort.thinking,
            provider_options: serde_json::json!({}),
        };

        let mut stream = match provider.create_message_stream(request).await {
            Ok(stream) => stream,
            Err(err) => {
                let message = err.to_string();
                delegate.on_error(message.clone());
                return Err(PocketError::Provider { message });
            }
        };

        let mut stop_reason = String::from("end_turn");
        while let Some(event) = stream.next().await {
            match event {
                Ok(StreamEvent::TextDelta { text, .. }) => delegate.on_text(text),
                Ok(StreamEvent::ThinkingDelta { thinking, .. }) => delegate.on_thinking(thinking),
                Ok(StreamEvent::MessageDelta {
                    stop_reason: reason,
                    ..
                }) => {
                    if let Some(reason) = reason {
                        stop_reason = format!("{reason:?}");
                    }
                }
                Ok(_) => {}
                Err(err) => {
                    let message = err.to_string();
                    delegate.on_error(message.clone());
                    return Err(PocketError::Provider { message });
                }
            }
        }

        delegate.on_done(stop_reason);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_reports_upstream_version() {
        let engine = PocketEngine::new();
        assert!(!engine.engine_version().is_empty());
        assert!(!engine.default_model().is_empty());
        assert!(!engine.default_codex_model().is_empty());
    }

    #[test]
    fn effort_maps_to_thinking_budgets() {
        let p = effort_params("claude-sonnet-4-5", Some("medium"), 4096);
        let thinking = p.thinking.expect("medium enables thinking");
        assert_eq!(thinking.thinking_type, "enabled");
        assert_eq!(thinking.budget_tokens, Some(5_000));
        assert_eq!(
            p.max_tokens,
            5_000 + 4096,
            "budget must fit under max_tokens"
        );
        assert_eq!(p.temperature, None);

        let p = effort_params("claude-sonnet-4-5", Some("max"), 4096);
        assert_eq!(
            p.thinking.expect("max enables thinking").budget_tokens,
            Some(20_000)
        );
    }

    #[test]
    fn low_effort_disables_thinking_and_pins_temperature() {
        let p = effort_params("claude-sonnet-4-5", Some("low"), 4096);
        assert!(p.thinking.is_none());
        assert_eq!(p.temperature, Some(0.0));
        assert_eq!(p.max_tokens, 4096);
    }

    #[test]
    fn adaptive_models_get_adaptive_thinking_without_budget() {
        let p = effort_params("claude-fable-5", Some("high"), 4096);
        let thinking = p.thinking.expect("adaptive thinking set");
        assert_eq!(thinking.thinking_type, "adaptive");
        assert_eq!(thinking.budget_tokens, None);
        assert_eq!(p.max_tokens, 4096);
    }

    #[test]
    fn absent_or_unknown_effort_leaves_request_untouched() {
        for effort in [None, Some("bogus")] {
            let p = effort_params("claude-sonnet-4-5", effort, 4096);
            assert!(p.thinking.is_none());
            assert_eq!(p.temperature, None);
            assert_eq!(p.max_tokens, 4096);
        }
    }

    struct Collector {
        text: std::sync::Mutex<String>,
        done: std::sync::atomic::AtomicBool,
    }

    impl StreamDelegate for Collector {
        fn on_text(&self, text: String) {
            if let Ok(mut buf) = self.text.lock() {
                buf.push_str(&text);
            }
        }
        fn on_thinking(&self, _text: String) {}
        fn on_done(&self, _stop_reason: String) {
            self.done.store(true, std::sync::atomic::Ordering::SeqCst);
        }
        fn on_error(&self, message: String) {
            panic!("stream error: {message}");
        }
    }

    /// Live smoke test — requires a real key:
    /// `ANTHROPIC_API_KEY=… cargo test -p coven-pocket-ffi -- --ignored`
    #[tokio::test]
    #[ignore = "requires ANTHROPIC_API_KEY and network"]
    async fn streams_a_live_completion() {
        let api_key = match std::env::var("ANTHROPIC_API_KEY") {
            Ok(key) if !key.is_empty() => key,
            _ => panic!("set ANTHROPIC_API_KEY to run this test"),
        };
        let engine = PocketEngine::new();
        let delegate = Arc::new(Collector {
            text: std::sync::Mutex::new(String::new()),
            done: std::sync::atomic::AtomicBool::new(false),
        });
        engine
            .stream_prompt(
                PocketProvider::Anthropic,
                api_key,
                claurst_core::constants::HAIKU_MODEL.to_string(),
                "Reply with the single word: pocket".to_string(),
                None,
                delegate.clone(),
            )
            .await
            .expect("stream completes");
        assert!(delegate.done.load(std::sync::atomic::Ordering::SeqCst));
        let text = delegate.text.lock().expect("lock").to_lowercase();
        assert!(text.contains("pocket"), "unexpected reply: {text}");
    }
}
