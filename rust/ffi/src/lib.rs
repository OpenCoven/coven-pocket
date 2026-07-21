//! coven-pocket-ffi: the UniFFI surface Coven Pocket's Swift app talks to.
//!
//! This crate is intentionally thin. Engine behavior (providers, streaming,
//! sessions) lives in the coven-code crates (`claurst-core`, `claurst-api`);
//! this layer only adapts types across the FFI boundary.

use std::sync::Arc;

use claurst_api::client::ClientConfig;
use claurst_api::provider::LlmProvider;
use claurst_api::provider_types::{ProviderRequest, StreamEvent};
use claurst_api::providers::AnthropicProvider;
use claurst_api::AnthropicClient;
use claurst_core::types::Message;
use futures::StreamExt;

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
        Ok(models
            .into_iter()
            .map(|m| PocketModel {
                id: m.id.to_string(),
                provider_id: m.provider_id.to_string(),
                name: m.name,
                context_window: m.context_window,
                max_output_tokens: m.max_output_tokens,
            })
            .collect())
    }

    /// Stream a single-turn completion, forwarding deltas to `delegate`.
    ///
    /// Resolves once the stream finishes; terminal state is reported through
    /// `on_done` / `on_error` as well so fire-and-forget callers stay correct.
    pub async fn stream_prompt(
        &self,
        api_key: String,
        model: String,
        prompt: String,
        delegate: Arc<dyn StreamDelegate>,
    ) -> Result<(), PocketError> {
        let provider = anthropic_provider(&api_key)?;
        let request = ProviderRequest {
            model,
            messages: vec![Message::user(prompt)],
            system_prompt: None,
            tools: Vec::new(),
            max_tokens: 4096,
            temperature: None,
            top_p: None,
            top_k: None,
            stop_sequences: Vec::new(),
            thinking: None,
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
                api_key,
                claurst_core::constants::HAIKU_MODEL.to_string(),
                "Reply with the single word: pocket".to_string(),
                delegate.clone(),
            )
            .await
            .expect("stream completes");
        assert!(delegate.done.load(std::sync::atomic::Ordering::SeqCst));
        let text = delegate.text.lock().expect("lock").to_lowercase();
        assert!(text.contains("pocket"), "unexpected reply: {text}");
    }
}
