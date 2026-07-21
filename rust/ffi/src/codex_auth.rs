//! Codex (OpenAI) OAuth login for Coven Pocket.
//!
//! Mirrors coven-code's CLI flow (`cli/src/codex_oauth_flow.rs`) adapted for
//! iOS: PKCE + a localhost callback listener bound inside the app sandbox.
//! The registered client redirects to `http://localhost:1455/auth/callback`,
//! which resolves to this in-app listener while the app presents the auth
//! page in an in-app browser. Engine-owned pieces (PKCE helpers, token
//! persistence, profile registry) come from `claurst-core`; only the
//! interactive glue lives here.

use std::sync::Arc;

use claurst_core::accounts::{jwt_identity, AccountRegistry, PROVIDER_CODEX};
use claurst_core::codex_oauth::{
    CODEX_AUTHORIZE_URL, CODEX_CLIENT_ID, CODEX_OAUTH_PORT, CODEX_REDIRECT_URI, CODEX_SCOPES,
    CODEX_TOKEN_URL,
};
use claurst_core::oauth_config::{
    clear_codex_tokens, get_codex_tokens, pkce, save_codex_tokens_and_register, CodexTokens,
};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

use crate::PocketError;

/// How long to wait for the user to finish the browser flow, including the
/// final token exchange.
const LOGIN_TIMEOUT_SECS: u64 = 300;

/// Bound on the token-exchange HTTP request so a stalled connection (Wi-Fi ↔
/// cellular handoff, captive portal) fails instead of wedging the login
/// future — on iOS there is no Ctrl-C to escape a hung sign-in.
const EXCHANGE_TIMEOUT_SECS: u64 = 30;

/// A signed-in Codex (ChatGPT) account.
#[derive(uniffi::Record)]
pub struct CodexAccount {
    pub profile_id: String,
    pub email: Option<String>,
    pub account_id: Option<String>,
}

/// Login-flow callbacks implemented on the Swift side.
///
/// Callbacks arrive on Rust worker threads; the Swift implementation is
/// responsible for hopping to the main actor before touching UI.
#[uniffi::export(with_foreign)]
pub trait CodexAuthDelegate: Send + Sync {
    /// The callback listener is ready; present `url` in a browser.
    fn on_auth_url(&self, url: String);
}

/// Build the OpenAI authorization URL.
///
/// Mirrors `build_auth_url` in coven-code's `cli/src/codex_oauth_flow.rs`;
/// that helper lives in the CLI crate (not linkable on iOS), so the query
/// shape is reproduced here from engine constants.
pub(crate) fn build_codex_auth_url(code_challenge: &str, state: &str) -> String {
    format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&code_challenge={}&code_challenge_method=S256&state={}&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=coven-code",
        CODEX_AUTHORIZE_URL,
        CODEX_CLIENT_ID,
        urlencoding::encode(CODEX_REDIRECT_URI),
        urlencoding::encode(CODEX_SCOPES),
        code_challenge,
        state,
    )
}

/// Run the interactive login: bind the callback listener, surface the auth
/// URL through `delegate`, wait for the redirect, exchange the code, and
/// persist tokens through the engine's profile registry.
///
/// The whole interactive portion (callback wait + token exchange) is bounded
/// by [`LOGIN_TIMEOUT_SECS`] so the future — and the Swift UI state awaiting
/// it — always resolves.
pub(crate) async fn login(
    delegate: Arc<dyn CodexAuthDelegate>,
) -> Result<CodexAccount, PocketError> {
    let verifier = pkce::generate_code_verifier();
    let challenge = pkce::code_challenge(&verifier);
    let state = pkce::generate_state();

    let listener = TcpListener::bind(("127.0.0.1", CODEX_OAUTH_PORT))
        .await
        .map_err(|e| PocketError::Engine {
            message: format!("failed to bind callback port {CODEX_OAUTH_PORT}: {e}"),
        })?;

    delegate.on_auth_url(build_codex_auth_url(&challenge, &state));

    let tokens = tokio::time::timeout(std::time::Duration::from_secs(LOGIN_TIMEOUT_SECS), async {
        let (code, callback_state) = wait_for_callback(listener).await?;
        if callback_state != state {
            return Err(PocketError::Provider {
                message: "OAuth state mismatch — aborting login".to_string(),
            });
        }
        exchange_code_for_tokens(&code, &verifier).await
    })
    .await
    .map_err(|_| PocketError::Provider {
        message: "login timed out waiting for the browser callback".to_string(),
    })??;

    let profile_id =
        save_codex_tokens_and_register(&tokens, None).map_err(|e| PocketError::Engine {
            message: format!("failed to persist Codex tokens: {e}"),
        })?;

    let identity = jwt_identity(&tokens.access_token);
    Ok(CodexAccount {
        profile_id,
        email: identity.email,
        account_id: tokens.account_id.or(identity.account_id),
    })
}

/// The active signed-in account, if any.
pub(crate) fn current_account() -> Option<CodexAccount> {
    // Presence of loadable tokens is the source of truth; the registry
    // profile carries the display identity.
    get_codex_tokens()?;
    let registry = AccountRegistry::load();
    let profile = registry.active_profile(PROVIDER_CODEX)?;
    Some(CodexAccount {
        profile_id: profile.id.clone(),
        email: profile.email.clone(),
        account_id: profile.account_id.clone(),
    })
}

/// Sign out: clear tokens and the active profile.
pub(crate) fn logout() -> Result<(), PocketError> {
    clear_codex_tokens().map_err(|e| PocketError::Engine {
        message: format!("failed to clear Codex tokens: {e}"),
    })
}

/// Accept connections until one carries the OAuth callback, then answer it
/// with a small success page. Non-callback requests (favicon probes and the
/// like) get a 404 so the browser keeps waiting on the right request.
async fn wait_for_callback(listener: TcpListener) -> Result<(String, String), PocketError> {
    loop {
        let (mut socket, _) = listener.accept().await.map_err(|e| PocketError::Engine {
            message: format!("failed to accept OAuth callback connection: {e}"),
        })?;

        let mut reader = BufReader::new(&mut socket);
        let mut request_line = String::new();
        if reader.read_line(&mut request_line).await.is_err() {
            continue;
        }

        match parse_callback_request(&request_line) {
            CallbackRequest::Callback { code, state } => {
                let body = "<html><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding-top:20vh\"><h2>Signed in</h2><p>Return to Coven Pocket.</p></body></html>";
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(response.as_bytes()).await;
                return Ok((code, state));
            }
            CallbackRequest::Denied { error } => {
                let body = "<html><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding-top:20vh\"><h2>Sign-in failed</h2><p>Return to Coven Pocket and try again.</p></body></html>";
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(response.as_bytes()).await;
                return Err(PocketError::Provider {
                    message: format!("authorization failed: {error}"),
                });
            }
            CallbackRequest::Other => {
                let _ = socket
                    .write_all(
                        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    )
                    .await;
            }
        }
    }
}

/// Parsed shape of one incoming request line on the callback listener.
enum CallbackRequest {
    Callback { code: String, state: String },
    Denied { error: String },
    Other,
}

/// Parse `GET /auth/callback?code=…&state=… HTTP/1.1` into its OAuth parts.
fn parse_callback_request(request_line: &str) -> CallbackRequest {
    let mut parts = request_line.split_whitespace();
    let (Some(method), Some(target)) = (parts.next(), parts.next()) else {
        return CallbackRequest::Other;
    };
    if method != "GET" {
        return CallbackRequest::Other;
    }
    let Some((path, query)) = target.split_once('?') else {
        return CallbackRequest::Other;
    };
    if path != "/auth/callback" {
        return CallbackRequest::Other;
    }

    let mut code = None;
    let mut state = None;
    let mut error = None;
    for pair in query.split('&') {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        let value = urlencoding::decode(value)
            .map(|v| v.into_owned())
            .unwrap_or_else(|_| value.to_string());
        match key {
            "code" => code = Some(value),
            "state" => state = Some(value),
            "error" => error = Some(value),
            _ => {}
        }
    }

    if let Some(error) = error {
        return CallbackRequest::Denied { error };
    }
    match (code, state) {
        (Some(code), Some(state)) => CallbackRequest::Callback { code, state },
        _ => CallbackRequest::Other,
    }
}

/// Exchange the authorization code for tokens.
///
/// Mirrors `exchange_code_for_tokens` in coven-code's CLI flow, including the
/// absolute `expires_at` computed from `expires_in` so the engine's
/// `CodexProvider` can refresh mid-session.
async fn exchange_code_for_tokens(code: &str, verifier: &str) -> Result<CodexTokens, PocketError> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(EXCHANGE_TIMEOUT_SECS))
        .build()
        .map_err(|e| PocketError::Engine {
            message: format!("failed to build HTTP client: {e}"),
        })?;
    let params = [
        ("client_id", CODEX_CLIENT_ID),
        ("code", code),
        ("code_verifier", verifier),
        ("grant_type", "authorization_code"),
        ("redirect_uri", CODEX_REDIRECT_URI),
    ];

    let resp = client
        .post(CODEX_TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| PocketError::Provider {
            message: format!("token exchange request failed: {e}"),
        })?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(PocketError::Provider {
            message: format!("token exchange failed ({status}): {body}"),
        });
    }

    let body: serde_json::Value = resp.json().await.map_err(|e| PocketError::Provider {
        message: format!("failed to parse token response: {e}"),
    })?;

    let access_token = body["access_token"].as_str().unwrap_or("").to_string();
    if access_token.is_empty() {
        return Err(PocketError::Provider {
            message: "token response missing access_token".to_string(),
        });
    }

    let refresh_token = body["refresh_token"].as_str().map(str::to_string);
    let account_id = jwt_identity(&access_token).account_id;
    let expires_at = body["expires_in"].as_u64().map(|secs| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
            + secs
    });

    Ok(CodexTokens {
        access_token,
        refresh_token,
        account_id,
        expires_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_url_carries_pkce_and_client_identity() {
        let url = build_codex_auth_url("challenge123", "state456");
        assert!(url.starts_with(CODEX_AUTHORIZE_URL));
        assert!(url.contains(&format!("client_id={CODEX_CLIENT_ID}")));
        assert!(url.contains("code_challenge=challenge123"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("state=state456"));
        assert!(url.contains(&format!(
            "redirect_uri={}",
            urlencoding::encode(CODEX_REDIRECT_URI)
        )));
        assert!(url.contains("originator=coven-code"));
    }

    #[test]
    fn callback_parser_extracts_code_and_state() {
        let parsed =
            parse_callback_request("GET /auth/callback?code=abc%2B1&state=xyz HTTP/1.1\r\n");
        match parsed {
            CallbackRequest::Callback { code, state } => {
                assert_eq!(code, "abc+1");
                assert_eq!(state, "xyz");
            }
            _ => panic!("expected callback"),
        }
    }

    #[test]
    fn callback_parser_reports_denial() {
        let parsed =
            parse_callback_request("GET /auth/callback?error=access_denied&state=xyz HTTP/1.1\r\n");
        match parsed {
            CallbackRequest::Denied { error } => assert_eq!(error, "access_denied"),
            _ => panic!("expected denial"),
        }
    }

    #[test]
    fn callback_parser_ignores_other_requests() {
        assert!(matches!(
            parse_callback_request("GET /favicon.ico HTTP/1.1\r\n"),
            CallbackRequest::Other
        ));
        assert!(matches!(
            parse_callback_request("POST /auth/callback?code=a&state=b HTTP/1.1\r\n"),
            CallbackRequest::Other
        ));
        assert!(matches!(parse_callback_request(""), CallbackRequest::Other));
    }

    #[tokio::test]
    async fn listener_answers_callback_and_returns_params() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();

        let client = tokio::spawn(async move {
            use tokio::io::AsyncReadExt;
            let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
            stream
                .write_all(b"GET /auth/callback?code=c0de&state=st HTTP/1.1\r\nHost: x\r\n\r\n")
                .await
                .unwrap();
            let mut buf = String::new();
            stream.read_to_string(&mut buf).await.unwrap();
            buf
        });

        let (code, state) = wait_for_callback(listener).await.unwrap();
        assert_eq!(code, "c0de");
        assert_eq!(state, "st");
        let response = client.await.unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains("Signed in"));
    }
}
