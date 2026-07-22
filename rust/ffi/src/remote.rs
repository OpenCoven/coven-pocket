//! Typed client for the paired daemon's `coven.daemon.v1` session API.
//!
//! Rides the same user-managed transport as the handshake (Tailscale/SSH
//! tunnel to the daemon's loopback TCP listener) and speaks plain
//! HTTP/1.1 with `Connection: close` — one short-lived connection per
//! call, which suits a phone app that polls in the foreground and goes
//! quiet in the background.

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::PocketError;

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
}

/// One redacted event row from the session event ledger. `payload_json`
/// is a stream-json frame (`system` / `user` / `assistant` / `tool_result`
/// / `output` / `result`); the app parses what it renders.
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
    let mut limited = stream.take(MAX_RESPONSE_BYTES);
    limited.read_to_end(&mut response).await?;
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
    let message = envelope
        .as_ref()
        .and_then(|v| v.get("error"))
        .and_then(|e| e.get("message"))
        .and_then(|m| m.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| format!("the daemon rejected the request (HTTP {status})"));
    PocketError::Engine { message }
}

fn daemon_shape_error(what: &str, err: serde_json::Error) -> PocketError {
    PocketError::Engine {
        message: format!("could not read the daemon's {what}: {err}"),
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
                "status":"running","created_at":"2026-01-01","updated_at":"2026-01-02"}]"#,
        )
        .await;
        let rows = sessions("127.0.0.1", port, TIMEOUT).await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "s-1");
        assert_eq!(rows[0].harness, "codex");
        assert_eq!(rows[0].status, "running");
        assert_eq!(rows[0].project_root, "/w");
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
}
