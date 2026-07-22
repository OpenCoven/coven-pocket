//! Reachability probe for a remote Coven daemon.
//!
//! MVP transport per the roadmap: the daemon's TCP listener stays loopback
//! on its host (`coven daemon --tcp <port>`), and the phone reaches it over
//! a user-managed path — a Tailscale network or an SSH tunnel
//! (`ssh -L <port>:localhost:<port> <host>`). This module only answers
//! "can I reach a healthy daemon at host:port, and what is it?"; pairing
//! and the `coven.daemon.v1` handshake build on it in a later milestone.

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

/// Probe a daemon's health endpoint over TCP.
pub(crate) async fn probe(host: &str, port: u16, timeout: Duration) -> DaemonProbeState {
    let started = Instant::now();

    // Resolve explicitly so DNS problems are distinguishable from dead hosts.
    let addrs = match tokio::net::lookup_host((host, port)).await {
        Ok(addrs) => addrs.collect::<Vec<_>>(),
        Err(_) => return DaemonProbeState::Unresolvable,
    };
    if addrs.is_empty() {
        return DaemonProbeState::Unresolvable;
    }

    let stream = match tokio::time::timeout(timeout, TcpStream::connect(addrs.as_slice())).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(e)) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
            return DaemonProbeState::Refused;
        }
        Ok(Err(e)) => {
            return DaemonProbeState::Failed {
                detail: e.to_string(),
            };
        }
        Err(_) => return DaemonProbeState::TimedOut,
    };

    match tokio::time::timeout(timeout, health_exchange(stream)).await {
        Ok(Ok(body)) => match parse_health(&body) {
            Some((pid, started_at)) => DaemonProbeState::Reachable {
                pid,
                started_at,
                latency_ms: started.elapsed().as_millis().min(u128::from(u32::MAX)) as u32,
            },
            None => DaemonProbeState::NotADaemon {
                detail: "the service at this address is not a healthy Coven daemon".to_string(),
            },
        },
        Ok(Err(e)) => DaemonProbeState::Failed {
            detail: e.to_string(),
        },
        Err(_) => DaemonProbeState::TimedOut,
    }
}

/// Send the same health request the CLI uses and return the raw response.
async fn health_exchange(mut stream: TcpStream) -> std::io::Result<String> {
    stream
        .write_all(b"GET /health HTTP/1.1\r\nHost: coven\r\nConnection: close\r\n\r\n")
        .await?;
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;
    Ok(String::from_utf8_lossy(&response).into_owned())
}

/// Pull `pid`/`startedAt` out of a `/health` response. Tolerant of framing:
/// scans for the JSON object rather than parsing HTTP headers strictly.
fn parse_health(response: &str) -> Option<(u32, String)> {
    let start = response.find('{')?;
    let end = response.rfind('}')?;
    let body: serde_json::Value = serde_json::from_str(&response[start..=end]).ok()?;
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
}
