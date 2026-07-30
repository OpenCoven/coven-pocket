# Familiar Companion Design

Date: 2026-07-30
Status: Approved for implementation under the repository autopilot objective
Issue: OpenCoven/coven-pocket#12
Bead: `pocket-eba`

## Goal

Let Coven Pocket users select one of their own Coven familiars and carry that
identity into either an on-device Codex session or a paired-daemon Claude
session. Selection persists independently for each Codex account and paired
daemon endpoint.

The app must match Coven's current familiar contract rather than restoring an
obsolete built-in roster.

## Upstream Alignment

Issue #12 says "7 archetypes", but that wording predates the current upstream
boundary. `OpenCoven/coven-code#93` deliberately removed seven hard-coded
personal familiars because a fresh install inherited identities and, for some
names, write/execute access. Current Coven and coven-code behavior is:

- the user's daemon-owned `familiars.toml` is the canonical roster;
- no named familiar ships as a default;
- identity injection uses the familiar's display name and optional role;
- unknown access values fail closed; and
- visual identity is generic and procedurally derived from the familiar ID.

Coven Pocket will therefore not embed named personas, descriptions presented
as canonical identity, or name-based permission grants. The issue is satisfied
as a roster-driven familiar companion, preserving the feature intent without
reviving the removed personal roster.

## Considered Approaches

### 1. Restore the seven named familiars in the app

This most literally follows the old issue wording, but conflicts with current
upstream behavior and recreates the privacy and privilege-inheritance problem
fixed by `coven-code#93`. Rejected.

### 2. Support familiars only for companion sessions

The app could fetch `GET /api/v1/familiars` and pass `familiarId` when launching
a daemon session. This is small and leaves identity fully daemon-owned, but it
does not satisfy the issue's app-wide session behavior and makes the picker
disappear when switching to on-device Codex. Rejected.

### 3. Use the daemon roster as canonical, with a safe local snapshot

Fetch the paired daemon roster, persist the selected ID and the selected
display-name/role snapshot per backend profile, pass the ID back to the daemon
for companion launches, and apply the same concise identity preamble to
on-device sessions. The daemon remains authoritative online; the snapshot lets
the selected familiar remain usable in the constrained on-device engine when
the daemon is temporarily unavailable. Recommended.

## Architecture

### Typed familiar record and daemon client

Add a UniFFI `RemoteFamiliar` record containing:

- `id`
- `display_name`
- optional `emoji`
- optional `role`
- optional `description`
- optional `pronouns`
- canonical `access`
- optional `model`

The Rust daemon client adds `GET /api/v1/familiars`, using the existing bounded
HTTP transport and structured error handling. Missing optional fields decode
as `None`; an absent display name falls back to the ID. Duplicate or blank IDs
are rejected from the client-visible list rather than becoming ambiguous
picker entries.

`remote_launch_session` gains an optional familiar ID and serializes it as
`familiarId`. The daemon resolves the ID against its live roster and remains
authoritative for companion launches.

### Selection model and persistence

A main-actor `FamiliarSelectionModel` owns:

- roster loading state;
- the most recent roster for each paired daemon endpoint;
- selected familiar snapshots; and
- profile-scoped selection lookup.

Selections persist in one versioned, Codable UserDefaults document. Profile
keys are:

- `codex:<profile-id>` for the active Codex account; and
- `companion:<host>:<port>` for a paired daemon.

The daemon process ID and start time are deliberately excluded: a normal
daemon restart must not erase the user's choice. Changing host or port selects
a distinct profile.

Each stored selection includes the ID, display name, and role used for identity
injection. Other roster fields are display metadata only. "None" is an explicit
selection and removes the stored entry for that profile.

Roster refresh always passes through `CompanionModel.gateForSessionTraffic()`.
Stale asynchronous refreshes use a generation check and cannot overwrite a
newer endpoint's roster or selection. A selected ID missing from a fresh roster
is cleared for that daemon profile; an offline cached snapshot remains valid
only until a successful roster refresh proves it was removed.

### Session identity

`ChatSettings` carries the selected familiar ID. A selection change is a
session-setting change, so the next send starts a new session instead of
changing identity inside an existing conversation.

For on-device Codex, `startChat` receives an optional typed familiar snapshot.
The Rust chat session appends the same concise identity block used by Coven:

```text
[Identity: You are <display name>, a <role>. Respond as <display name>, not as the underlying tool.]
```

When no role exists, the role clause is omitted. Familiar text is data: it
does not replace the platform sandbox note, change tool registration, or alter
the active permission mode. The familiar's daemon `access` and `model` fields
are shown for context but do not grant capabilities or silently override the
user's selected model.

For companion Claude, Pocket sends only the selected familiar ID. The daemon
injects its current identity representation and rejects stale/unknown IDs.
Pocket never sends its cached prose as a privileged daemon system prompt.

The familiar snapshot is persisted with an on-device session's metadata.
Resume and fork preserve the original snapshot so a stored conversation cannot
silently change identity when the profile's current selection changes. Existing
sessions migrate with no familiar.

Companion session reuse is additionally bound to the selected familiar ID.
Changing familiars retires the old live session through the existing retryable
cleanup path before launching the replacement.

### SwiftUI

Chat Settings gains a `Familiar` section:

- a picker with "None" plus the current daemon roster;
- compact name, emoji, role, and access presentation;
- loading and actionable pairing/refresh failures; and
- a short note that familiars shape identity but do not widen iOS permissions.

The picker remains available for Codex using the last validated roster
snapshot. If no roster has ever been loaded, it explains that familiars come
from the paired Coven daemon instead of presenting built-in placeholders.

The active familiar appears as a small toolbar/menu label in Chat so the
identity in force is visible without reopening settings. No custom portrait or
seven-name art ships in this change.

## Data Flow

1. Chat becomes active or settings opens.
2. The selection model verifies the current pairing and fetches the roster.
3. The model derives the current profile key and restores its selected
   snapshot.
4. The user selects a familiar or None.
5. The selection is persisted and copied into `ChatSettings`.
6. On the next send:
   - Codex receives the stored snapshot in `startChat`; or
   - Companion receives the familiar ID in `POST /sessions`.
7. Session metadata pins that identity until reset, fork, or a new session.

## Error Handling

- Pairing or roster failures are visible and retain the last validated cached
  selection without claiming the roster is current.
- Unknown daemon familiar IDs fail the launch visibly; there is no launch
  without identity and no fallback to cached prompt injection.
- Malformed roster entries are skipped individually; a malformed top-level
  response fails the request.
- Persistence decode failure resets only familiar preferences and reports no
  success-shaped state.
- Stale refresh, launch, and cleanup outcomes cannot publish over a newer
  pairing, backend, or familiar selection.

## Testing

Rust tests cover roster decoding, optional/default fields, malformed and
duplicate IDs, request bounds, `familiarId` launch serialization, and omission
when None.

Swift tests cover:

- profile-key isolation;
- persistence round trips and corrupt-state recovery;
- endpoint restart versus endpoint change;
- stale refresh suppression;
- clearing a removed familiar after a successful refresh;
- exact identity preamble rendering;
- no permission/model escalation;
- on-device resume and fork identity pinning;
- companion reuse rejection after familiar changes; and
- settings picker loading, empty, cached, and failure states through model
  tests rather than brittle view inspection.

The final gate is the existing XCFramework build, Rust tests/check/clippy/fmt,
strict SwiftLint, full iOS simulator tests, generic simulator build, and GitHub
CI.

## Out of Scope

- Creating, editing, or deleting the daemon roster.
- Reintroducing seven built-in personal familiar names.
- Importing protected Familiar Contract files onto the device.
- Letting familiar access tiers override iOS sandbox or permission modes.
- Custom familiar image generation or remote asset download.
- Multi-familiar orchestration or handoff.

## Acceptance Criteria

1. A paired user's current daemon roster is selectable in Chat.
2. Selection persists independently for Codex accounts and daemon endpoints.
3. New Codex and companion sessions receive the selected identity through
   their authoritative integration path.
4. Existing sessions pin identity across resume and fork.
5. Selecting a familiar never widens tools, permissions, or model access.
6. No built-in named roster is added.
7. All repository quality gates and CI pass.
