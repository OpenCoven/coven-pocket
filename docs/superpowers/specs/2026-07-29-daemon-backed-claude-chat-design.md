# Daemon-Backed Claude Chat Design

**Status:** Implemented; corrected against the daemon stream contract on 2026-07-29
**Bead:** `pocket-d3u`
**GitHub issue:** `OpenCoven/coven-pocket#9`

## Objective

Replace Chat's direct Anthropic API-key path with Claude subscription access
through the paired Coven daemon. The daemon launches the host's signed-in
`claude` CLI, while Coven Pocket renders and controls that daemon-owned session.
Claude OAuth credentials never leave the host.

This change preserves on-device Codex and the Playground. The Playground may
continue exercising the direct Anthropic provider for development, but the
user-facing Chat surface must not ask for or send an Anthropic API key.

## Existing Contracts

Coven Pocket already:

- stores a confirmed daemon pairing in the Keychain;
- verifies `coven.daemon.v1` before session traffic;
- lists daemon sessions;
- polls `/api/v1/sessions/:id/events`;
- sends data through `/api/v1/sessions/:id/input`;
- kills sessions through `/api/v1/sessions/:id/kill`; and
- maps daemon event rows into a remote transcript.

The Coven daemon already accepts `POST /api/v1/sessions`. A Claude conversation
can use:

```json
{
  "projectRoot": "/absolute/path/on/the/daemon/host",
  "cwd": "/absolute/path/on/the/daemon/host",
  "harness": "claude",
  "prompt": "First user turn",
  "title": "First user turn",
  "launchMode": "stream"
}
```

`launchMode: "stream"` starts Claude Code with its stream-JSON transport. The
daemon delivers the first prompt during launch, converts later `/input` data
into stream messages, records output in its event ledger, and owns process
lifecycle. No provider proxy or new daemon endpoint is required.

## Product Behavior

### Provider selection

Chat offers:

- **Claude via Companion** when a stored pairing has just passed the mandatory
  daemon handshake; and
- **Codex** when the app has an on-device Codex account.

The Anthropic API-key provider is removed from Chat. It must not appear as a
fallback when the daemon is unavailable. If Claude via Companion was selected
and the pairing becomes unavailable, sending is blocked with an actionable
connection error.

The companion option is not considered available merely because pairing data
exists in the Keychain. Chat verifies the pairing on appearance and before
launching or controlling a daemon session.

### Remote project root

The daemon requires an explicit project boundary and cannot access the iOS
sandbox path. Claude via Companion therefore adds a required **Project path on
daemon host** field. The value:

- is trimmed and persisted in `UserDefaults`;
- must be an absolute-looking non-empty path before Send is enabled;
- is sent as both `projectRoot` and `cwd`; and
- is still canonicalized and enforced by the daemon.

Pocket does not attempt to translate an iOS repository path into a host path.
Project discovery and cross-device workspace reconciliation remain outside this
issue.

### Conversation lifecycle

The first Claude turn:

1. verifies the stored pairing;
2. launches a daemon session with `harness: "claude"` and
   `launchMode: "stream"`;
3. stores the returned session id in the Chat model; and
4. starts polling the session event ledger from sequence zero.

Later turns re-verify the pairing and send the prompt to the live session's
`/input` endpoint. Polling continues from the daemon-provided
`nextCursor.afterSeq`; events are accumulated and deterministically remapped
into Chat rows.

Stop re-verifies the pairing and calls `/kill`. Reset cancels polling and kills
an active daemon session before clearing local presentation state. The app
never silently changes backends or replays the prompt through a provider API.

### Transcript and permission behavior

The existing `RemoteTranscript` parser remains the authority for daemon event
payloads. A small mapping layer converts its roles into the existing Chat
surface:

- user → user bubble;
- assistant → assistant text;
- terminal → terminal/status card;
- tool result → tool card; and
- result/system → status.

For a stream-mode Claude session, a `result` frame means **turn complete**;
it does not mean that the daemon session or CLI process exited. The companion
Chat mapper therefore renders turn-complete copy and keeps polling. The
existing one-shot remote-attach mapper retains its session-finished copy.

Companion Chat does not synthesize Approve or Deny controls from stream output.
For stream sessions, `/input` wraps every payload as a new Claude user-message
envelope, so forwarding `y` or `n` would create a chat turn rather than answer
a PTY prompt. The existing Remote Attach surface retains its approval controls
because it attaches to interactive sessions where `/input` is terminal input.

The Chat share sheet continues to operate on rendered, already-redacted daemon
events. Raw daemon artifacts are not fetched by this feature.

### Settings and local-only features

When Claude via Companion is selected:

- Chat shows daemon identity/connection state and the daemon project path;
- Chat does not show an Anthropic API key, local model catalog, effort picker,
  local memory injection, or local permission mode;
- the session-history action opens daemon sessions; and
- local workspace paths are not sent to the daemon.

When Codex is selected, the existing on-device session, permission, memory, and
workspace behavior remains unchanged.

Remote model selection is not introduced here. The host's configured Claude
default is used. Adding a daemon-backed model catalog is a separate capability,
not a reason to retain the Anthropic API path.

## Code Boundaries

### Rust FFI transport

`rust/ffi/src/remote.rs` gains a typed `launch` operation that:

- serializes the exact daemon launch body;
- POSTs `/api/v1/sessions`;
- parses the returned snake-case `SessionRecord`; and
- reuses the existing bounded HTTP transport and structured daemon errors.

`PocketEngine` exposes this as `remote_launch_session`. The FFI stays a thin
transport adapter; it does not contain provider selection or chat policy.

### Swift companion chat

The Swift layer introduces a daemon-chat state object with an injectable
session-client protocol. Its responsibilities are:

- pairing gates;
- first-turn launch;
- subsequent input;
- event polling and cursor ownership;
- kill/reset; and
- mapping remote transcript rows into Chat presentation state.

`ChatView` selects between this state object and the existing on-device Codex
model. Backend-specific settings remain separate so a daemon project path is
never mistaken for an iOS workspace path.

The production session client combines `CompanionModel` and `PocketEngine`.
Tests substitute an in-memory client and do not touch the Keychain or network.

## Error Handling

- **Not paired:** block send and direct the user to Companion.
- **Handshake failure/version mismatch:** show the existing actionable pairing
  copy and do not launch.
- **Missing project path:** keep Send disabled and identify the required field.
- **Invalid/outside-root host path:** surface the daemon's structured
  `invalid_request` response.
- **Missing or unauthenticated `claude` CLI:** surface the daemon's
  `launch_failed` message; do not request credentials on-device.
- **Polling failure:** keep the session id and cursor, show the error, and allow
  a retry without duplicating already-seen events.
- **Session no longer live:** stop accepting input and retain the transcript.
- **Cancellation:** cancel polling promptly; only an explicit Stop or Reset
  kills the host process.

No failure mode falls back to Anthropic HTTP.

## Testing

Implementation follows red-green-refactor.

Rust transport tests prove:

- the exact `POST /api/v1/sessions` path and launch JSON;
- `harness: "claude"` and `launchMode: "stream"`;
- project root and cwd preservation;
- returned session parsing;
- response-size enforcement; and
- structured launch errors.

Swift tests prove:

- Claude via Companion is unavailable without a freshly verified pairing;
- the first turn launches exactly once;
- later turns use `/input` rather than launching another session;
- event cursors advance without duplicate rows;
- stream output never exposes false PTY approval controls;
- Stop routes to the daemon;
- pairing, launch, and polling failures do not fall back to a provider API;
- reset cancels and kills an active remote session;
- daemon project paths never reuse iOS workspace paths; and
- Chat contains no Anthropic API-key field or Keychain read.

Verification includes:

```bash
cd rust
cargo test -p coven-pocket-ffi
cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings
cargo fmt --all --check
cd ..
swiftlint lint --strict
./scripts/build-xcframework.sh
xcodegen generate
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'generic/platform=iOS Simulator' build
git diff --check
```

The generated `CovenPocket.xcodeproj` is never committed.

## Completion Criteria

The feature is complete only when:

1. Chat's Claude path launches and controls the paired daemon's signed-in
   `claude` CLI.
2. Chat no longer reads, displays, or submits an Anthropic API key.
3. Pairing is freshly verified before daemon traffic.
4. First turn, follow-up input, events, Stop, and Reset all use the daemon
   session contract; Chat does not treat stream `/input` as PTY approval input.
5. No daemon failure silently falls back to a provider API.
6. On-device Codex and the Playground remain functional.
7. Focused tests and the full repository quality gates pass.
8. `ROADMAP.md` marks the M2 item complete.
