//! Reachability probe and `coven.daemon.v1` handshake for a remote daemon.
//!
//! MVP transport per the roadmap: the daemon's TCP listener stays loopback
//! on its host (`coven daemon --tcp <port>`), and the phone reaches it over
//! a user-managed path — a Tailscale network or an SSH tunnel
//! (`ssh -L <port>:localhost:<port> <host>`). [`probe`] answers "can I
//! reach a healthy daemon at host:port?"; [`handshake`] performs the
//! versioned `GET /api/v1/health` exchange and refuses anything that does
//! not speak `coven.daemon.v1`, so pairing can gate session traffic on it.

use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// Outcome of probing `host:port`. Failure variants are deliberately
/// specific so the UI can say what to check instead of "error".
#[derive(uniffi::Enum, Debug)]
pub enum DaemonProbeState {
    /// A healthy daemon answered.
    Reachable {
        pid: u32,
        started_at: String,
        latency_ms: u32,
    },
    /// TCP connected but the response was not a healthy Coven daemon.
    NotADaemon { detail: String },
    /// Connection refused — nothing listening (tunnel down, wrong port).
    Refused,
    /// No answer in time — wrong host, VPN down, or a firewall drop.
    TimedOut,
    /// The hostname did not resolve.
    Unresolvable,
    /// Anything else, with the underlying error text.
    Failed { detail: String },
}

/// The protocol contract this app requires before any session traffic.
pub(crate) const REQUIRED_API_VERSION: &str = "coven.daemon.v1";

/// What a daemon reported about itself during a successful handshake.
#[derive(uniffi::Record, Debug, Clone)]
pub struct DaemonIdentity {
    pub api_version: String,
    pub coven_version: String,
    pub pid: u32,
    pub started_at: String,
    pub sessions: bool,
    pub events: bool,
}

/// Outcome of the mandatory `coven.daemon.v1` handshake.
#[derive(uniffi::Enum, Debug)]
pub enum DaemonHandshake {
    /// The daemon speaks `coven.daemon.v1`; pairing may proceed.
    Compatible {
        identity: DaemonIdentity,
        latency_ms: u32,
    },
    /// A Coven daemon answered, but with a different protocol version.
    /// `reported` is what it offered (or "unversioned" for pre-v1 daemons).
    VersionMismatch { reported: String },
    /// TCP connected but the response was not a Coven daemon at all.
    NotADaemon { detail: String },
    /// Connection refused — nothing listening (tunnel down, wrong port).
    Refused,
    /// No answer in time — wrong host, VPN down, or a firewall drop.
    TimedOut,
    /// The hostname did not resolve.
    Unresolvable,
    /// Anything else, with the underlying error text.
    Failed { detail: String },
}

/// Transport-level result of one HTTP exchange, shared by probe and handshake.
enum Exchange {
    Response { body: String, latency_ms: u32 },
    Refused,
    TimedOut,
    Unresolvable,
    Failed(String),
}

/// Probe a daemon's health endpoint over TCP.
pub(crate) async fn probe(host: &str, port: u16, timeout: Duration) -> DaemonProbeState {
    match fetch(host, port, "/health", timeout).await {
        Exchange::Response { body, latency_ms } => match parse_health(&body) {
            Some((pid, started_at)) => DaemonProbeState::Reachable {
                pid,
                started_at,
                latency_ms,
            },
            None => DaemonProbeState::NotADaemon {
                detail: "the service at this address is not a healthy Coven daemon".to_string(),
            },
        },
        Exchange::Refused => DaemonProbeState::Refused,
        Exchange::TimedOut => DaemonProbeState::TimedOut,
        Exchange::Unresolvable => DaemonProbeState::Unresolvable,
        Exchange::Failed(detail) => DaemonProbeState::Failed { detail },
    }
}

/// Perform the `coven.daemon.v1` handshake: fetch the versioned health
/// endpoint and accept only a daemon that speaks the required contract.
pub(crate) async fn handshake(host: &str, port: u16, timeout: Duration) -> DaemonHandshake {
    match fetch(host, port, "/api/v1/health", timeout).await {
        Exchange::Response { body, latency_ms } => classify_handshake(&body, latency_ms),
        Exchange::Refused => DaemonHandshake::Refused,
        Exchange::TimedOut => DaemonHandshake::TimedOut,
        Exchange::Unresolvable => DaemonHandshake::Unresolvable,
        Exchange::Failed(detail) => DaemonHandshake::Failed { detail },
    }
}

/// One GET over a fresh TCP connection, under a single timeout budget
/// spanning DNS resolution, connect, and the exchange.
async fn fetch(host: &str, port: u16, path: &str, timeout: Duration) -> Exchange {
    let started = Instant::now();

    // Resolve explicitly so DNS problems are distinguishable from dead
    // hosts — and inside the budget, since a slow resolver hangs too.
    let addrs = match tokio::time::timeout(timeout, tokio::net::lookup_host((host, port))).await {
        Ok(Ok(addrs)) => addrs.collect::<Vec<_>>(),
        Ok(Err(_)) => return Exchange::Unresolvable,
        Err(_) => return Exchange::TimedOut,
    };
    if addrs.is_empty() {
        return Exchange::Unresolvable;
    }

    let remaining = timeout.saturating_sub(started.elapsed());
    if remaining.is_zero() {
        return Exchange::TimedOut;
    }
    let stream = match tokio::time::timeout(remaining, TcpStream::connect(addrs.as_slice())).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(e)) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
            return Exchange::Refused;
        }
        Ok(Err(e)) => return Exchange::Failed(e.to_string()),
        Err(_) => return Exchange::TimedOut,
    };

    // The exchange only gets whatever the earlier phases left over.
    let remaining = timeout.saturating_sub(started.elapsed());
    if remaining.is_zero() {
        return Exchange::TimedOut;
    }
    match tokio::time::timeout(remaining, http_get(stream, path)).await {
        Ok(Ok(body)) => Exchange::Response {
            body,
            latency_ms: started.elapsed().as_millis().min(u128::from(u32::MAX)) as u32,
        },
        Ok(Err(e)) => Exchange::Failed(e.to_string()),
        Err(_) => Exchange::TimedOut,
    }
}

/// Cap on any buffered response. A real health payload is a few hundred
/// bytes; the address is user-supplied, so an arbitrary service must not
/// be able to balloon memory.
const MAX_RESPONSE_BYTES: u64 = 64 * 1024;

/// Send the same minimal request the CLI uses and return the raw response.
async fn http_get(mut stream: TcpStream, path: &str) -> std::io::Result<String> {
    let request = format!("GET {path} HTTP/1.1\r\nHost: coven\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).await?;
    let mut response = Vec::new();
    let mut limited = stream.take(MAX_RESPONSE_BYTES);
    limited.read_to_end(&mut response).await?;
    Ok(String::from_utf8_lossy(&response).into_owned())
}

/// Pull the JSON object out of a raw HTTP response. Tolerant of framing:
/// scans for braces rather than parsing headers strictly.
fn extract_json(response: &str) -> Option<serde_json::Value> {
    let start = response.find('{')?;
    let end = response.rfind('}')?;
    if end < start {
        return None;
    }
    serde_json::from_str(&response[start..=end]).ok()
}

/// Pull `pid`/`startedAt` out of a `/health` response.
fn parse_health(response: &str) -> Option<(u32, String)> {
    let body = extract_json(response)?;
    if !body.get("ok")?.as_bool()? {
        return None;
    }
    let daemon = body.get("daemon")?;
    let pid = u32::try_from(daemon.get("pid")?.as_u64()?).ok()?;
    let started_at = daemon
        .get("startedAt")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    Some((pid, started_at))
}

/// Decide what a `/api/v1/health` response means for pairing.
fn classify_handshake(response: &str, latency_ms: u32) -> DaemonHandshake {
    let Some(body) = extract_json(response) else {
        return DaemonHandshake::NotADaemon {
            detail: "the service at this address did not answer with a Coven health response"
                .to_string(),
        };
    };

    // A daemon that rejects /api/v1/* announces what it does support in a
    // structured error envelope — that is a version mismatch, not garbage.
    if let Some(error) = body.get("error") {
        let supported = error
            .get("details")
            .and_then(|d| d.get("supportedApiVersions"))
            .and_then(|v| v.as_array())
            .map(|versions| {
                versions
                    .iter()
                    .filter_map(|v| v.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|s| !s.is_empty());
        if let Some(reported) = supported {
            return DaemonHandshake::VersionMismatch { reported };
        }
        return DaemonHandshake::NotADaemon {
            detail: "the service at this address is not a healthy Coven daemon".to_string(),
        };
    }

    if !body.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        return DaemonHandshake::NotADaemon {
            detail: "the daemon answered but reported itself unhealthy".to_string(),
        };
    }

    match body.get("apiVersion").and_then(|v| v.as_str()) {
        Some(REQUIRED_API_VERSION) => {}
        Some(other) => {
            return DaemonHandshake::VersionMismatch {
                reported: other.to_string(),
            };
        }
        // Healthy but unversioned: a daemon from before the v1 contract.
        None => {
            return DaemonHandshake::VersionMismatch {
                reported: "unversioned (pre-v1)".to_string(),
            };
        }
    }

    let Some(daemon) = body.get("daemon").filter(|d| !d.is_null()) else {
        return DaemonHandshake::NotADaemon {
            detail: "the daemon answered without identifying itself".to_string(),
        };
    };
    // Refuse to pair on an incomplete identity: a health payload without a
    // usable pid is not something we can show the user or persist.
    let Some(pid) = daemon
        .get("pid")
        .and_then(|v| v.as_u64())
        .and_then(|v| u32::try_from(v).ok())
    else {
        return DaemonHandshake::NotADaemon {
            detail: "the daemon answered without identifying itself".to_string(),
        };
    };
    let started_at = daemon
        .get("startedAt")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let capability = |name: &str| {
        body.get("capabilities")
            .and_then(|c| c.get(name))
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    };
    DaemonHandshake::Compatible {
        identity: DaemonIdentity {
            api_version: REQUIRED_API_VERSION.to_string(),
            coven_version: body
                .get("covenVersion")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
                .to_string(),
            pid,
            started_at,
            sessions: capability("sessions"),
            events: capability("events"),
        },
        latency_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;
    use tokio::net::TcpListener;

    const TIMEOUT: Duration = Duration::from_millis(1500);

    async fn serve_once(response: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf).await;
                let _ = stream.write_all(response.as_bytes()).await;
            }
        });
        port
    }

    #[tokio::test]
    async fn healthy_daemon_is_reachable() {
        let port = serve_once(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\
             {\"ok\":true,\"daemon\":{\"pid\":4242,\"startedAt\":\"2026-01-01T00:00:00Z\",\"socket\":\"/tmp/d.sock\"}}",
        )
        .await;
        match probe("127.0.0.1", port, TIMEOUT).await {
            DaemonProbeState::Reachable {
                pid, started_at, ..
            } => {
                assert_eq!(pid, 4242);
                assert_eq!(started_at, "2026-01-01T00:00:00Z");
            }
            other => panic!("expected Reachable, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn non_daemon_service_is_flagged() {
        let port = serve_once("HTTP/1.1 200 OK\r\n\r\nwelcome to nginx").await;
        assert!(matches!(
            probe("127.0.0.1", port, TIMEOUT).await,
            DaemonProbeState::NotADaemon { .. }
        ));
    }

    #[tokio::test]
    async fn unhealthy_daemon_is_flagged() {
        let port = serve_once("HTTP/1.1 200 OK\r\n\r\n{\"ok\":false,\"daemon\":null}").await;
        assert!(matches!(
            probe("127.0.0.1", port, TIMEOUT).await,
            DaemonProbeState::NotADaemon { .. }
        ));
    }

    #[tokio::test]
    async fn closed_port_is_refused() {
        // Bind then drop to find a port with no listener.
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            listener.local_addr().unwrap().port()
        };
        assert!(matches!(
            probe("127.0.0.1", port, TIMEOUT).await,
            DaemonProbeState::Refused
        ));
    }

    #[tokio::test]
    async fn silent_server_times_out() {
        // Accepts but never responds: the read phase must time out.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _held = listener.accept().await;
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        assert!(matches!(
            probe("127.0.0.1", port, Duration::from_millis(300)).await,
            DaemonProbeState::TimedOut
        ));
    }

    #[tokio::test]
    async fn bad_hostname_is_unresolvable() {
        assert!(matches!(
            probe("definitely-not-a-real-host.invalid", 7777, TIMEOUT).await,
            DaemonProbeState::Unresolvable
        ));
    }

    #[test]
    fn parse_health_survives_hostile_framing() {
        // Closing brace before the first opening brace must not slice-panic.
        assert!(parse_health("}{").is_none());
        assert!(parse_health("HTTP/1.1 200 OK\r\n\r\n} banner {").is_none());
        assert!(parse_health("no braces at all").is_none());
    }

    #[tokio::test]
    async fn oversized_responses_are_capped_not_buffered() {
        // 1 MiB of garbage: the probe must stop at the cap and classify the
        // service as not-a-daemon rather than buffering everything.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf).await;
                let chunk = vec![b'x'; 1024 * 1024];
                let _ = stream.write_all(&chunk).await;
            }
        });
        assert!(matches!(
            probe("127.0.0.1", port, TIMEOUT).await,
            DaemonProbeState::NotADaemon { .. }
        ));
    }

    const V1_HEALTH: &str = concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        "{\"ok\":true,\"apiVersion\":\"coven.daemon.v1\",\"covenVersion\":\"0.3.0\",",
        "\"capabilities\":{\"sessions\":true,\"events\":true},",
        "\"daemon\":{\"pid\":31415,\"startedAt\":\"2026-05-15T19:31:02Z\",\"socket\":\"/tmp/d.sock\"}}"
    );

    #[tokio::test]
    async fn handshake_accepts_v1_daemon_and_reads_identity() {
        let port = serve_once(V1_HEALTH).await;
        match handshake("127.0.0.1", port, TIMEOUT).await {
            DaemonHandshake::Compatible { identity, .. } => {
                assert_eq!(identity.api_version, "coven.daemon.v1");
                assert_eq!(identity.coven_version, "0.3.0");
                assert_eq!(identity.pid, 31415);
                assert_eq!(identity.started_at, "2026-05-15T19:31:02Z");
                assert!(identity.sessions);
                assert!(identity.events);
            }
            other => panic!("expected Compatible, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn handshake_requests_the_versioned_path() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::oneshot::channel::<String>();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let _ = tx.send(String::from_utf8_lossy(&buf[..n]).into_owned());
                let _ = stream.write_all(V1_HEALTH.as_bytes()).await;
            }
        });
        let _ = handshake("127.0.0.1", port, TIMEOUT).await;
        let request = rx.await.unwrap_or_default();
        assert!(
            request.starts_with("GET /api/v1/health HTTP/1.1"),
            "got: {request}"
        );
    }

    #[tokio::test]
    async fn handshake_rejects_a_newer_protocol() {
        let port = serve_once(
            "HTTP/1.1 200 OK\r\n\r\n\
             {\"ok\":true,\"apiVersion\":\"coven.daemon.v2\",\"daemon\":{\"pid\":1}}",
        )
        .await;
        match handshake("127.0.0.1", port, TIMEOUT).await {
            DaemonHandshake::VersionMismatch { reported } => {
                assert_eq!(reported, "coven.daemon.v2");
            }
            other => panic!("expected VersionMismatch, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn handshake_rejects_an_unversioned_daemon() {
        let port = serve_once(
            "HTTP/1.1 200 OK\r\n\r\n{\"ok\":true,\"daemon\":{\"pid\":7,\"startedAt\":\"x\"}}",
        )
        .await;
        assert!(matches!(
            handshake("127.0.0.1", port, TIMEOUT).await,
            DaemonHandshake::VersionMismatch { reported } if reported.contains("unversioned")
        ));
    }

    #[tokio::test]
    async fn handshake_reads_supported_versions_from_error_envelope() {
        let port = serve_once(
            "HTTP/1.1 404 Not Found\r\n\r\n\
             {\"error\":{\"code\":\"invalid_request\",\"message\":\"Unsupported API version.\",\
             \"details\":{\"apiVersion\":\"v1\",\"supportedApiVersions\":[\"v2\",\"v3\"]}}}",
        )
        .await;
        match handshake("127.0.0.1", port, TIMEOUT).await {
            DaemonHandshake::VersionMismatch { reported } => assert_eq!(reported, "v2, v3"),
            other => panic!("expected VersionMismatch, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn handshake_flags_non_daemon_services() {
        let port = serve_once("HTTP/1.1 200 OK\r\n\r\nwelcome to nginx").await;
        assert!(matches!(
            handshake("127.0.0.1", port, TIMEOUT).await,
            DaemonHandshake::NotADaemon { .. }
        ));
        let port =
            serve_once("HTTP/1.1 404 Not Found\r\n\r\n{\"error\":{\"code\":\"nope\"}}").await;
        assert!(matches!(
            handshake("127.0.0.1", port, TIMEOUT).await,
            DaemonHandshake::NotADaemon { .. }
        ));
    }

    #[tokio::test]
    async fn handshake_rejects_identity_without_a_pid() {
        let port = serve_once(
            "HTTP/1.1 200 OK\r\n\r\n\
             {\"ok\":true,\"apiVersion\":\"coven.daemon.v1\",\"daemon\":{\"startedAt\":\"x\"}}",
        )
        .await;
        assert!(matches!(
            handshake("127.0.0.1", port, TIMEOUT).await,
            DaemonHandshake::NotADaemon { .. }
        ));
    }

    #[tokio::test]
    async fn handshake_maps_transport_failures() {
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            listener.local_addr().unwrap().port()
        };
        assert!(matches!(
            handshake("127.0.0.1", port, TIMEOUT).await,
            DaemonHandshake::Refused
        ));
        assert!(matches!(
            handshake("definitely-not-a-real-host.invalid", 7777, TIMEOUT).await,
            DaemonHandshake::Unresolvable
        ));
    }
}
