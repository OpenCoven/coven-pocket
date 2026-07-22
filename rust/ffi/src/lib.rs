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

pub use chat::{
    ChatDelegate, ChatMessage, ChatPermissionDecision, ChatPermissionMode, ChatPermissionRequest,
    ChatPermissionResponder, ChatSession,
};
pub use codex_auth::{CodexAccount, CodexAuthDelegate};

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
    pub fn start_chat(
        &self,
        provider: PocketProvider,
        api_key: String,
        model: String,
        effort: Option<String>,
        workspace_dir: String,
        permission_mode: ChatPermissionMode,
    ) -> Result<Arc<ChatSession>, PocketError> {
        chat::start_session(
            provider,
            api_key,
            model,
            effort,
            workspace_dir,
            permission_mode,
        )
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
