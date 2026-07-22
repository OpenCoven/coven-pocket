# Roadmap

Coven Pocket delivers coven-code's core functionality on iOS as a hybrid app:
an on-device agent (BYO credentials, sandbox-safe tools) plus a companion mode
that pairs with the [Coven daemon](https://github.com/OpenCoven/coven) for
full-capability remote sessions.

## M0 — Foundation (done)

- [x] Licensing decision record — GPL-3.0 posture, distribution channels
      (`docs/LICENSING.md`)
- [x] Repo scaffold — SwiftUI app, `rust/ffi` UniFFI crate over pinned
      coven-code engine crates, XCFramework pipeline, CI
- [x] iOS spike — `claurst-core` + `claurst-api` compile for
      `aarch64-apple-ios{,-sim}`; engine runs on-simulator (smoke tests);
      streaming surface exercised via `StreamDelegate` (live test is
      env-gated on `ANTHROPIC_API_KEY`)
- [x] Tool sandbox profile — resolved without an upstream split:
      `claurst-tools` compiles for iOS as-is, and coven-code already ships a
      security-reviewed file-tools allowlist pattern
      (`filter_tools_for_hosted_review` over `all_tools()`, guarded by the
      exhaustive `hosted_repair_allows_only_repository_file_tools` test).
      M1 wires the same allowlist (Read/Grep/Glob/Edit/Write/ApplyPatch/
      BatchEdit/NotebookEdit) into the on-device loop; process tools are
      excluded at registry build time, not compile time.

## M1 — On-device agent core

- [x] Provider auth: Anthropic API key (Keychain) and Codex OAuth (PKCE +
      in-app localhost callback, tokens in the engine's profile registry
      inside the app sandbox), per-provider model picker with effort control.
      Known limits at the current engine pin: Anthropic OAuth login is
      unavailable (the OSS engine ships an intentionally empty OAuth
      `client_id`), and the Codex Responses adapter does not yet encode a
      reasoning-effort control, so effort maps to Anthropic extended
      thinking only.
- [x] On-device git workspaces (libgit2; HTTPS PAT + SSH keys)
- [x] Chat surface wired to the agentic query loop (tool-call cards, stop/retry)
- [x] Permission modes + approval sheets (default / accept-edits / plan)
- [ ] Native diff viewer with per-hunk accept/reject
- [x] Session browser: resume, fork, delete

## M2 — Companion mode

- [x] Daemon transport (Tailscale/SSH tunnel MVP; upstream design for an
      authenticated remote listener)
- [ ] Pairing flow with mandatory `coven.daemon.v1` handshake
- [ ] Remote session attach: live events, input forwarding, remote approvals
- [ ] Anthropic subscription access via the companion's `claude` CLI login:
      the engine's `ClaudeCliProvider` delegates to the signed-in binary and
      never imports its OAuth tokens (`bearer_auth_is_usable` rejects tokens
      minted for other clients — replaying them gets rate limited). On-device
      Anthropic therefore stays API-key only.
- [ ] Goal handoff between device and desktop

## M3 — Extended scope

- [ ] Memory: AGENTS.md injection, memdir browser
- [ ] Familiar companion (7 archetypes)
- [ ] On-device `/goal` with Live Activity progress
- [ ] Remote MCP servers (streamable HTTP/SSE + OAuth)
- [ ] Session sharing via unlisted Gists

## M4 — Platform polish

- [ ] Live Activities + Dynamic Island; approval notifications
- [ ] App Intents / Shortcuts / Spotlight
- [ ] iPad three-pane layout
- [ ] TestFlight beta (subject to the licensing gate)
