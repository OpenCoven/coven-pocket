//! Typed client for the paired daemon's `coven.daemon.v1` session API.
//!
//! Rides the same user-managed transport as the handshake (Tailscale/SSH
//! tunnel to the daemon's loopback TCP listener) and speaks plain
//! HTTP/1.1 with `Connection: close` — one short-lived connection per
//! call, which suits a phone app that polls in the foreground and goes
//! quiet in the background.

use std::collections::HashSet;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::PocketError;

/// A familiar the UI can identify without loading the full roster row.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct FamiliarIdentity {
    pub id: String,
    pub display_name: String,
    pub emoji: Option<String>,
    pub role: Option<String>,
}

/// One familiar row from `GET /api/v1/familiars`.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RemoteFamiliar {
    pub id: String,
    pub display_name: String,
    pub emoji: Option<String>,
    pub role: Option<String>,
    pub description: Option<String>,
    pub pronouns: Option<String>,
    pub icon: Option<String>,
}

/// One session row from `GET /api/v1/sessions`.
#[derive(uniffi::Record, Debug, Clone)]
pub struct RemoteSession {
    pub id: String,
    pub harness: String,
    pub title: String,
    pub status: String,
    pub project_root: String,
    pub created_at: String,
    pub updated_at: String,
    pub familiar_id: Option<String>,
}

/// One redacted event row from the session event ledger. For `output`
/// rows, `payload_json.data` contains a raw stdout chunk that may split
/// stream-json frames across rows; the app reassembles what it renders.
#[derive(uniffi::Record, Debug, Clone)]
pub struct RemoteEvent {
    pub seq: i64,
    pub kind: String,
    pub payload_json: String,
    pub created_at: String,
}

/// A page of events plus the cursor to resume from.
#[derive(uniffi::Record, Debug, Clone)]
pub struct RemoteEventBatch {
    pub events: Vec<RemoteEvent>,
    /// Pass as `after_seq` on the next poll. Equal to the request cursor
    /// when the page was empty.
    pub next_after_seq: i64,
    pub has_more: bool,
}

/// Launch a long-lived Claude stream session on the paired daemon.
pub(crate) async fn launch(
    host: &str,
    port: u16,
    project_root: &str,
    prompt: &str,
    title: &str,
    familiar_id: Option<&str>,
    timeout: Duration,
) -> Result<RemoteSession, PocketError> {
    let mut payload = serde_json::Map::from_iter([
        (
            "projectRoot".to_string(),
            serde_json::Value::String(project_root.to_string()),
        ),
        (
            "cwd".to_string(),
            serde_json::Value::String(project_root.to_string()),
        ),
        (
            "harness".to_string(),
            serde_json::Value::String("claude".to_string()),
        ),
        (
            "prompt".to_string(),
            serde_json::Value::String(prompt.to_string()),
        ),
        (
            "title".to_string(),
            serde_json::Value::String(title.to_string()),
        ),
        (
            "launchMode".to_string(),
            serde_json::Value::String("stream".to_string()),
        ),
    ]);
    if let Some(familiar_id) = familiar_id.and_then(trimmed_nonblank) {
        payload.insert(
            "familiarId".to_string(),
            serde_json::Value::String(familiar_id),
        );
    }
    let payload = serde_json::Value::Object(payload).to_string();
    let body = request(
        host,
        port,
        "POST",
        "/api/v1/sessions",
        Some(&payload),
        timeout,
    )
    .await?;
    let row: serde_json::Value = serde_json::from_str(&body)
        .map_err(|error| daemon_shape_error("launched session", error))?;
    Ok(session_from(&row))
}

/// List familiars on the daemon, in daemon order.
pub(crate) async fn familiars(
    host: &str,
    port: u16,
    timeout: Duration,
) -> Result<Vec<RemoteFamiliar>, PocketError> {
    let body = request(host, port, "GET", "/api/v1/familiars", None, timeout).await?;
    let rows: Vec<DaemonFamiliar> = serde_json::from_str(&body)
        .map_err(|error| daemon_shape_error("familiar roster", error))?;
    let mut seen_ids = HashSet::new();
    let mut familiars = Vec::with_capacity(rows.len());
    for row in rows {
        let familiar = row.normalize()?;
        let canonical_id = familiar.id.to_lowercase();
        if !seen_ids.insert(canonical_id) {
            return Err(familiar_roster_error(format!(
                "duplicate familiar id `{}`",
                familiar.id
            )));
        }
        familiars.push(familiar);
    }
    Ok(familiars)
}

/// List sessions on the daemon, newest first as the daemon returns them.
pub(crate) async fn sessions(
    host: &str,
    port: u16,
    timeout: Duration,
) -> Result<Vec<RemoteSession>, PocketError> {
    let body = request(host, port, "GET", "/api/v1/sessions", None, timeout).await?;
    let rows: Vec<serde_json::Value> =
        serde_json::from_str(&body).map_err(|e| daemon_shape_error("session list", e))?;
    Ok(rows.iter().map(session_from).collect())
}

/// Read one page of a session's events after `after_seq`.
pub(crate) async fn events(
    host: &str,
    port: u16,
    session_id: &str,
    after_seq: i64,
    limit: u32,
    timeout: Duration,
) -> Result<RemoteEventBatch, PocketError> {
    let path = format!(
        "/api/v1/sessions/{}/events?afterSeq={after_seq}&limit={limit}",
        encode_path_segment(session_id)
    );
    let body = request(host, port, "GET", &path, None, timeout).await?;
    let page: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| daemon_shape_error("event page", e))?;
    let events = page
        .get("events")
        .and_then(|v| v.as_array())
        .map(|rows| rows.iter().map(event_from).collect::<Vec<_>>())
        .unwrap_or_default();
    let next_after_seq = page
        .get("nextCursor")
        .and_then(|c| c.get("afterSeq"))
        .and_then(|v| v.as_i64())
        .unwrap_or_else(|| events.last().map(|e| e.seq).unwrap_or(after_seq));
    Ok(RemoteEventBatch {
        has_more: page
            .get("hasMore")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        events,
        next_after_seq,
    })
}

/// Forward input to a live session (`{ "data": ... }` contract).
pub(crate) async fn send_input(
    host: &str,
    port: u16,
    session_id: &str,
    data: &str,
    timeout: Duration,
) -> Result<(), PocketError> {
    let path = format!("/api/v1/sessions/{}/input", encode_path_segment(session_id));
    let payload = serde_json::json!({ "data": data }).to_string();
    request(host, port, "POST", &path, Some(&payload), timeout).await?;
    Ok(())
}

/// Kill a live session.
pub(crate) async fn kill(
    host: &str,
    port: u16,
    session_id: &str,
    timeout: Duration,
) -> Result<(), PocketError> {
    let path = format!("/api/v1/sessions/{}/kill", encode_path_segment(session_id));
    request(host, port, "POST", &path, None, timeout).await?;
    Ok(())
}

fn session_from(row: &serde_json::Value) -> RemoteSession {
    let text = |key: &str| {
        row.get(key)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string()
    };
    RemoteSession {
        id: text("id"),
        harness: text("harness"),
        title: text("title"),
        status: text("status"),
        project_root: text("project_root"),
        created_at: text("created_at"),
        updated_at: text("updated_at"),
        familiar_id: optional_json_text(row, "familiar_id"),
    }
}

fn event_from(row: &serde_json::Value) -> RemoteEvent {
    let text = |key: &str| {
        row.get(key)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string()
    };
    RemoteEvent {
        seq: row.get("seq").and_then(|v| v.as_i64()).unwrap_or_default(),
        kind: text("kind"),
        payload_json: text("payload_json"),
        created_at: text("created_at"),
    }
}

#[derive(Debug, serde::Deserialize)]
struct DaemonFamiliar {
    #[serde(default)]
    id: String,
    #[serde(default)]
    display_name: String,
    emoji: Option<String>,
    role: Option<String>,
    description: Option<String>,
    pronouns: Option<String>,
    icon: Option<String>,
}

impl DaemonFamiliar {
    fn normalize(self) -> Result<RemoteFamiliar, PocketError> {
        let id = trimmed_nonblank(self.id.as_str())
            .ok_or_else(|| familiar_roster_error("familiar id cannot be blank"))?;
        let display_name =
            trimmed_nonblank(self.display_name.as_str()).unwrap_or_else(|| id.clone());
        Ok(RemoteFamiliar {
            id,
            display_name,
            emoji: trim_optional(self.emoji),
            role: trim_optional(self.role),
            description: trim_optional(self.description),
            pronouns: trim_optional(self.pronouns),
            icon: trim_optional(self.icon),
        })
    }
}

fn optional_json_text(row: &serde_json::Value, key: &str) -> Option<String> {
    row.get(key)
        .and_then(|value| value.as_str())
        .and_then(trimmed_nonblank)
}

fn trim_optional(value: Option<String>) -> Option<String> {
    value.as_deref().and_then(trimmed_nonblank)
}

fn trimmed_nonblank(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Percent-encode a session id for use as one path segment. Daemon ids are
/// UUID-like, but the id came over the wire — never let it splice a path.
fn encode_path_segment(segment: &str) -> String {
    let mut encoded = String::with_capacity(segment.len());
    for byte in segment.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char);
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    encoded
}

/// Cap on any buffered response body. Event pages are bounded by `limit`,
/// but the transport must not trust the peer.
const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;

/// One HTTP exchange against the daemon. Success (2xx) returns the body;
/// a structured daemon error becomes a [`PocketError`] with its message;
/// transport failures get actionable text.
async fn request(
    host: &str,
    port: u16,
    method: &str,
    path: &str,
    json_body: Option<&str>,
    timeout: Duration,
) -> Result<String, PocketError> {
    let exchange = async {
        let stream = TcpStream::connect((host, port)).await?;
        write_request(stream, method, path, json_body).await
    };
    let raw = tokio::time::timeout(timeout, exchange)
        .await
        .map_err(|_| PocketError::Engine {
            message: "the daemon did not answer in time; check the tunnel or Tailscale".into(),
        })?
        .map_err(|e: std::io::Error| PocketError::Engine {
            message: format!("could not reach the daemon: {e}"),
        })?;
    let (status, body) = split_response(&raw);
    if (200..300).contains(&status) {
        return Ok(body);
    }
    Err(daemon_error(status, &body))
}

async fn write_request(
    mut stream: TcpStream,
    method: &str,
    path: &str,
    json_body: Option<&str>,
) -> std::io::Result<String> {
    let body = json_body.unwrap_or_default();
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: coven\r\nConnection: close\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
        body.len(),
    );
    stream.write_all(request.as_bytes()).await?;
    let mut response = Vec::new();
    // Read one byte past the cap so truncation is detected, not silent.
    let mut limited = stream.take(MAX_RESPONSE_BYTES + 1);
    limited.read_to_end(&mut response).await?;
    if response.len() as u64 > MAX_RESPONSE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("daemon response exceeded the {MAX_RESPONSE_BYTES}-byte cap"),
        ));
    }
    Ok(String::from_utf8_lossy(&response).into_owned())
}

/// Split a raw HTTP/1.1 response into status code and body.
fn split_response(raw: &str) -> (u16, String) {
    let status = raw
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .unwrap_or(0);
    let body = raw
        .split_once("\r\n\r\n")
        .map(|(_, body)| body.to_string())
        .unwrap_or_default();
    (status, body)
}

/// Turn a non-2xx daemon response into an error carrying the structured
/// envelope's message when present.
fn daemon_error(status: u16, body: &str) -> PocketError {
    let envelope: Option<serde_json::Value> = serde_json::from_str(body).ok();
    let error = envelope.as_ref().and_then(|value| value.get("error"));
    let detail = error
        .and_then(|value| value.get("message"))
        .and_then(|value| value.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| format!("the daemon rejected the request (HTTP {status})"));
    let message = error
        .and_then(|value| value.get("code"))
        .and_then(|value| value.as_str())
        .map(|code| format!("{code}: {detail}"))
        .unwrap_or(detail);
    PocketError::Engine { message }
}

fn daemon_shape_error(what: &str, err: serde_json::Error) -> PocketError {
    PocketError::Engine {
        message: format!("could not read the daemon's {what}: {err}"),
    }
}

fn familiar_roster_error(detail: impl Into<String>) -> PocketError {
    PocketError::Engine {
        message: format!(
            "could not read the daemon's familiar roster: {}",
            detail.into()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;
    use tokio::net::TcpListener;

    const TIMEOUT: Duration = Duration::from_millis(1500);

    /// Serve one canned HTTP response and capture the request line + body.
    async fn serve_once(
        status_line: &'static str,
        body: &'static str,
    ) -> (u16, tokio::sync::oneshot::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = vec![0u8; 16 * 1024];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let _ = tx.send(String::from_utf8_lossy(&buf[..n]).into_owned());
                let response = format!(
                    "{status_line}\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len(),
                );
                let _ = stream.write_all(response.as_bytes()).await;
            }
        });
        (port, rx)
    }

    #[tokio::test]
    async fn lists_sessions_from_snake_case_rows() {
        let (port, _rx) = serve_once(
            "HTTP/1.1 200 OK",
            r#"[{"id":"s-1","project_root":"/w","harness":"codex","title":"Fix bug",
                "familiar_id":" sage ",
                "status":"running","created_at":"2026-01-01","updated_at":"2026-01-02"}]"#,
        )
        .await;
        let rows = sessions("127.0.0.1", port, TIMEOUT).await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "s-1");
        assert_eq!(rows[0].harness, "codex");
        assert_eq!(rows[0].status, "running");
        assert_eq!(rows[0].project_root, "/w");
        assert_eq!(rows[0].familiar_id.as_deref(), Some("sage"));
    }

    #[tokio::test]
    async fn lists_familiars_from_roster_and_normalizes_fields() {
        let (port, rx) = serve_once(
            "HTTP/1.1 200 OK",
            r#"[{"id":" sage ","display_name":"  Sage  ","emoji":" owl ","role":" Guide ",
                "description":" Explains tradeoffs. ","pronouns":" they/them ",
                "icon":" ph:owl-fill "},
               {"id":"forge","display_name":"   ","emoji":" ","role":null}]"#,
        )
        .await;

        let rows = familiars("127.0.0.1", port, TIMEOUT).await.unwrap();

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].id, "sage");
        assert_eq!(rows[0].display_name, "Sage");
        assert_eq!(rows[0].emoji.as_deref(), Some("owl"));
        assert_eq!(rows[0].role.as_deref(), Some("Guide"));
        assert_eq!(rows[0].description.as_deref(), Some("Explains tradeoffs."));
        assert_eq!(rows[0].pronouns.as_deref(), Some("they/them"));
        assert_eq!(rows[0].icon.as_deref(), Some("ph:owl-fill"));
        assert_eq!(rows[1].id, "forge");
        assert_eq!(rows[1].display_name, "forge");
        assert_eq!(rows[1].emoji, None);
        assert_eq!(rows[1].role, None);

        let request = rx.await.unwrap();
        assert!(
            request.starts_with("GET /api/v1/familiars HTTP/1.1"),
            "got: {request}"
        );
    }

    #[tokio::test]
    async fn blank_familiar_ids_reject_the_whole_roster() {
        let (port, _rx) =
            serve_once("HTTP/1.1 200 OK", r#"[{"id":"   ","display_name":"Sage"}]"#).await;

        let err = familiars("127.0.0.1", port, TIMEOUT).await.unwrap_err();
        assert!(
            err.to_string().contains("familiar id cannot be blank"),
            "got: {err}"
        );
    }

    #[tokio::test]
    async fn duplicate_familiar_ids_reject_the_whole_roster() {
        let (port, _rx) = serve_once(
            "HTTP/1.1 200 OK",
            r#"[{"id":"sage","display_name":"Sage"},{"id":"SAGE","display_name":"Other"}]"#,
        )
        .await;

        let err = familiars("127.0.0.1", port, TIMEOUT).await.unwrap_err();
        assert!(
            err.to_string().contains("duplicate familiar id"),
            "got: {err}"
        );
    }

    #[tokio::test]
    async fn malformed_familiar_roster_uses_the_daemon_shape_error_style() {
        let (port, _rx) = serve_once("HTTP/1.1 200 OK", r#"{"items":[]}"#).await;

        let err = familiars("127.0.0.1", port, TIMEOUT).await.unwrap_err();
        assert!(
            err.to_string()
                .contains("could not read the daemon's familiar roster"),
            "got: {err}"
        );
    }

    #[tokio::test]
    async fn launches_claude_stream_session_with_explicit_host_root() {
        let (port, rx) = serve_once(
            "HTTP/1.1 201 Created",
            r#"{"id":"s-claude","project_root":"/srv/repo","harness":"claude",
                "title":"Fix tests","status":"running",
                "created_at":"2026-07-29T00:00:00Z",
                "updated_at":"2026-07-29T00:00:00Z"}"#,
        )
        .await;

        let session = launch(
            "127.0.0.1",
            port,
            "/srv/repo",
            "Fix tests",
            "Fix tests",
            None,
            TIMEOUT,
        )
        .await
        .unwrap();

        assert_eq!(session.id, "s-claude");
        assert_eq!(session.harness, "claude");
        assert_eq!(session.project_root, "/srv/repo");

        let request = rx.await.unwrap();
        assert!(
            request.starts_with("POST /api/v1/sessions HTTP/1.1"),
            "got: {request}"
        );
        let body = request.split_once("\r\n\r\n").unwrap().1;
        let payload: serde_json::Value = serde_json::from_str(body).unwrap();
        assert_eq!(payload["projectRoot"], "/srv/repo");
        assert_eq!(payload["cwd"], "/srv/repo");
        assert_eq!(payload["harness"], "claude");
        assert_eq!(payload["prompt"], "Fix tests");
        assert_eq!(payload["title"], "Fix tests");
        assert_eq!(payload["launchMode"], "stream");
        assert!(payload.get("apiKey").is_none());
        assert!(payload.get("familiarId").is_none());
    }

    #[tokio::test]
    async fn launch_serializes_trimmed_familiar_id_when_present() {
        let (port, rx) = serve_once(
            "HTTP/1.1 201 Created",
            r#"{"id":"s-claude","project_root":"/srv/repo","harness":"claude",
                "title":"Fix tests","status":"running","familiar_id":"sage",
                "created_at":"2026-07-29T00:00:00Z",
                "updated_at":"2026-07-29T00:00:00Z"}"#,
        )
        .await;

        let session = launch(
            "127.0.0.1",
            port,
            "/srv/repo",
            "Fix tests",
            "Fix tests",
            Some(" sage "),
            TIMEOUT,
        )
        .await
        .unwrap();

        assert_eq!(session.familiar_id.as_deref(), Some("sage"));

        let request = rx.await.unwrap();
        let body = request.split_once("\r\n\r\n").unwrap().1;
        let payload: serde_json::Value = serde_json::from_str(body).unwrap();
        assert_eq!(payload["familiarId"], "sage");
    }

    #[tokio::test]
    async fn launch_surfaces_the_daemon_auth_failure_without_fallback() {
        let (port, _rx) = serve_once(
            "HTTP/1.1 500 Internal Server Error",
            r#"{"error":{"code":"launch_failed","message":"claude is not signed in"}}"#,
        )
        .await;

        let error = launch(
            "127.0.0.1",
            port,
            "/srv/repo",
            "hello",
            "hello",
            None,
            TIMEOUT,
        )
        .await
        .unwrap_err();

        assert!(error.to_string().contains("claude is not signed in"));
    }

    #[tokio::test]
    async fn reads_event_pages_and_cursor() {
        let (port, rx) = serve_once(
            "HTTP/1.1 200 OK",
            r#"{"events":[
                {"seq":7,"id":"e-7","session_id":"s-1","kind":"assistant",
                 "payload_json":"{\"type\":\"assistant\"}","created_at":"t"}],
                "nextCursor":{"afterSeq":7},"hasMore":true}"#,
        )
        .await;
        let page = events("127.0.0.1", port, "s-1", 3, 100, TIMEOUT)
            .await
            .unwrap();
        assert_eq!(page.events.len(), 1);
        assert_eq!(page.events[0].seq, 7);
        assert_eq!(page.events[0].kind, "assistant");
        assert_eq!(page.next_after_seq, 7);
        assert!(page.has_more);
        let request = rx.await.unwrap();
        assert!(
            request.starts_with("GET /api/v1/sessions/s-1/events?afterSeq=3&limit=100"),
            "got: {request}"
        );
    }

    #[tokio::test]
    async fn empty_event_page_keeps_the_cursor() {
        let (port, _rx) = serve_once(
            "HTTP/1.1 200 OK",
            r#"{"events":[],"nextCursor":null,"hasMore":false}"#,
        )
        .await;
        let page = events("127.0.0.1", port, "s-1", 42, 100, TIMEOUT)
            .await
            .unwrap();
        assert!(page.events.is_empty());
        assert_eq!(page.next_after_seq, 42);
        assert!(!page.has_more);
    }

    #[tokio::test]
    async fn send_input_posts_the_data_contract() {
        let (port, rx) = serve_once("HTTP/1.1 200 OK", r#"{"ok":true,"accepted":true}"#).await;
        send_input("127.0.0.1", port, "s-1", "y\n", TIMEOUT)
            .await
            .unwrap();
        let request = rx.await.unwrap();
        assert!(
            request.starts_with("POST /api/v1/sessions/s-1/input"),
            "got: {request}"
        );
        assert!(request.ends_with(r#"{"data":"y\n"}"#), "got: {request}");
    }

    #[tokio::test]
    async fn structured_daemon_errors_surface_their_message() {
        let (port, _rx) = serve_once(
            "HTTP/1.1 409 Conflict",
            r#"{"error":{"code":"session_not_live","message":"Session is not live."}}"#,
        )
        .await;
        let err = send_input("127.0.0.1", port, "s-1", "hi", TIMEOUT)
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("Session is not live."),
            "got: {err}"
        );
        assert!(err.to_string().contains("session_not_live"), "got: {err}");
    }

    #[tokio::test]
    async fn kill_posts_to_the_kill_route() {
        let (port, rx) = serve_once("HTTP/1.1 200 OK", r#"{"ok":true,"accepted":true}"#).await;
        kill("127.0.0.1", port, "s-1", TIMEOUT).await.unwrap();
        let request = rx.await.unwrap();
        assert!(
            request.starts_with("POST /api/v1/sessions/s-1/kill"),
            "got: {request}"
        );
    }

    #[tokio::test]
    async fn unreachable_daemon_is_an_actionable_error() {
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            listener.local_addr().unwrap().port()
        };
        let err = sessions("127.0.0.1", port, TIMEOUT).await.unwrap_err();
        assert!(
            err.to_string().contains("could not reach the daemon"),
            "got: {err}"
        );
    }

    #[test]
    fn path_segments_cannot_splice_routes() {
        assert_eq!(encode_path_segment("s-1"), "s-1");
        assert_eq!(encode_path_segment("../events?x=1"), "..%2Fevents%3Fx%3D1");
        assert_eq!(encode_path_segment("a b"), "a%20b");
    }

    #[tokio::test]
    async fn oversized_responses_fail_loudly_instead_of_truncating() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = vec![0u8; 16 * 1024];
                let _ = stream.read(&mut buf).await;
                let body = "x".repeat(MAX_RESPONSE_BYTES as usize + 1);
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len(),
                );
                let _ = stream.write_all(response.as_bytes()).await;
            }
        });
        let err = sessions("127.0.0.1", port, Duration::from_secs(10))
            .await
            .unwrap_err();
        let text = format!("{err:?}");
        assert!(text.contains("byte cap"), "unexpected error: {text}");
    }
}
