# On-Device Goals with Live Activity Progress

**Date:** 2026-07-31
**Status:** Approved

## Summary

Coven Pocket will add an on-device `/goal` workflow for Codex sessions. A user
can start a bounded autonomous objective, inspect it, pause it, resume it, or
clear it. The app will show durable in-app state and a privacy-safe Live
Activity while execution is active.

The coven-code engine remains authoritative for goal persistence, continuation
messages, completion, budgets, and runaway protection. Pocket will first
upstream path-scoped goal APIs, pin the resulting coven-code revision, and add
only the iOS orchestration needed to run that state machine inside the app
sandbox.

iOS does not guarantee indefinite background execution. Pocket will continue a
running goal only during the finite background time granted by
`UIApplication`; it will persist and pause the goal when that time expires.
Live Activities report progress but do not imply that model or tool execution
continues indefinitely off-screen.

## Goals

- Support these on-device Codex commands:
  - `/goal <objective>`
  - `/goal --tokens <budget> <objective>`
  - `/goal status`
  - `/goal pause`
  - `/goal resume`
  - `/goal clear`
- Reuse coven-code's goal state machine instead of recreating it in Swift or
  Pocket's FFI.
- Persist goal status and cumulative progress by the real chat session ID.
- Run autonomous continuation turns under one cancellation scope and one
  cumulative token-accounting scope.
- Expose `GoalComplete` only while an on-device goal is running.
- Show in-app goal progress and a goal-specific Live Activity.
- Pause safely at user request, background expiration, runtime failure, or
  process-relaunch reconciliation.
- Preserve Pocket's sandbox, storage, tool-permission, and session-lifecycle
  boundaries.

## Non-Goals

- Companion or daemon-owned goals.
- Indefinite background execution, `BGProcessingTask` continuation, or any
  other claim that iOS will keep a goal continuously running.
- Remote Live Activity push updates.
- Ordinary chat Live Activities, approval notifications, interactive
  notification actions, or a rich general-purpose Dynamic Island experience;
  those remain issue #16.
- New tools, broader tool permissions, process spawning, PTY access, or shell
  execution on-device.
- Multiple simultaneously executing goals.
- Changing the model, account, working directory, Familiar identity, or tool
  policy when a goal starts.

## Constraints and Existing Behavior

The pinned coven-code revision already provides:

- `GoalStore`, `Goal`, and `GoalStatus`;
- objective-length validation and optional soft token budgets;
- durable SQLite persistence;
- goal system-prompt and continuation-message construction;
- `check_and_continue_goal`;
- `GoalCompleteTool`; and
- a 200-turn runaway guard.

Those APIs currently open a desktop-global default database. `GoalCompleteTool`
also opens that default store, so changing only the continuation function would
split one goal across two databases. Pocket cannot redirect this safely with a
process-global environment variable.

Pocket's current FFI creates a generated `pocket-*` tool-context session ID and
a new `CostTracker` for each ordinary user turn. A goal needs the canonical
`ChatSession.session_id` for storage and tool completion, and its token usage
must remain cumulative across all autonomous turns and later resumes.

Pocket intentionally excludes `GoalComplete` from its normal on-device tool
registry. That exclusion remains the default.

## Approaches Considered

### 1. Upstream a path-scoped goal boundary and reuse it from Pocket

Add explicit-store APIs to coven-code, make `GoalCompleteTool` constructible
with the same store path, and let Pocket orchestrate the returned continuation
decisions.

This is the selected approach. It keeps persistence and state-machine behavior
in coven-code, avoids global path mutation, and gives Pocket only the lifecycle
responsibilities that are specific to iOS.

### 2. Copy the goal loop into `rust/ffi`

Pocket could reproduce the goal schema, prompts, budget checks, and completion
semantics locally. This would work without an upstream change but would fork
engine behavior and create two implementations that can drift. It is rejected.

### 3. Route all goals through Companion mode

A daemon could run indefinitely and publish remote progress. That is useful for
a future Companion feature, but it does not satisfy issue #13's on-device
requirement and would make a paired daemon mandatory. It is rejected.

## Architecture

The feature has five bounded components:

1. **coven-code goal APIs** own durable state transitions, progress accounting,
   continuation decisions, and goal completion at an explicit database path.
2. **Pocket Rust goal runner** adapts those APIs to the existing on-device query
   loop and Pocket's checked storage and tool registry.
3. **Swift command and state layer** parses `/goal`, owns the current UI
   snapshot, routes lifecycle operations, and bridges Rust callbacks to
   `@MainActor`.
4. **Goal execution coordinator** maps app scene transitions and finite iOS
   background time to pause/cancel behavior.
5. **Goal Live Activity manager and widget extension** render bounded,
   privacy-safe progress without controlling execution.

Each layer consumes typed state from the layer below it. Swift does not infer
goal status from transcript text, and ActivityKit does not become a second
source of truth.

## Upstream coven-code Changes

Pocket will upstream the reusable changes before changing its engine pin.

### Explicit store path

The query crate will expose a path-scoped continuation entry point alongside
the existing desktop-default wrapper. The tool crate will allow
`GoalCompleteTool` to be constructed with an explicit goal database path.
Default desktop construction will keep using `GoalStore::open_default()`, so
existing CLI callers remain source- and behavior-compatible.

Both continuation and completion must open the same explicit store. The new
APIs will accept a `&Path`; they will not mutate environment variables or
global configuration.

### Atomic completed-turn accounting

`GoalStore` will atomically record a completed turn's:

- absolute cumulative token total;
- elapsed seconds; and
- turn count.

The stored token value is monotonic. A stale or lower absolute total must not
reduce previously recorded usage. Continuation checks will operate on the
durably recorded values after the completed turn is accounted for.

This closes the current gap where `check_and_continue_goal` consults a runtime
token total but never updates `Goal.tokens_used`. It also lets a resumed Pocket
run start from the stored total without double-counting.

### Status transition errors

Path-scoped helpers must distinguish:

- no goal for the session;
- a goal that is paused, budget-limited, or complete;
- a storage/open failure; and
- a progress-write failure.

No storage failure may be converted to `NoGoal` or apparent success. Existing
desktop wrappers can preserve their public shape, but the new reusable boundary
must return explicit errors to Pocket.

### Completion tool

`GoalCompleteTool` constructed for Pocket will:

- use the explicit store path;
- use `ToolContext.session_id`;
- reject empty audit summary or evidence as it does today; and
- report a failure if no matching active goal is updated.

The upstream change must therefore make status transitions verify that they
actually affected the intended goal.

### Pin discipline

The upstream PR will be tested and merged first. Pocket will then update the
git `rev` in `rust/Cargo.toml`, regenerate the XCFramework and Swift bindings,
and note the engine-visible change in the commit message. No generated Swift
file will be edited manually.

## Pocket Storage and Session Identity

Pocket will store goals in one SQLite database under its existing checked
session-storage root. A dedicated goal-store path keeps goal schema ownership
with coven-code while allowing Pocket to validate the app-owned path and SQLite
sidecars before use.

The storage wrapper will apply the same relevant protections as session
persistence:

- canonical app-owned root containment;
- rejection of symlinked database or sidecar files;
- bounded path and metadata handling;
- explicit open and migration errors; and
- serialized access where Pocket's lifecycle operations can race.

The goal key is the canonical `ChatSession.session_id`. Goal turns will set
`ToolContext.session_id` to that same value. Generated `pocket-*` identifiers
will no longer be used for goal completion.

A session delete clears its goal in the same coordinated lifecycle operation.
If clearing the goal fails, deletion fails visibly rather than leaving a
detached goal. Recovery of an unpublished or invalid session also clears any
matching goal. Forked sessions do not inherit the source goal.

## Rust FFI Goal Boundary

The FFI will expose typed goal records and lifecycle operations rather than a
generic command string.

### Types

`GoalSnapshot` contains:

- goal ID;
- session ID;
- objective;
- status (`active`, `paused`, `budgetLimited`, or `complete`);
- optional token budget;
- cumulative tokens used;
- cumulative elapsed seconds;
- turns used; and
- updated timestamp.

`GoalRunStopReason` distinguishes completion, user/background pause,
budget limit, runaway guard, cancellation, and runtime/storage error. The
persisted goal status remains coven-code's status; a runtime error transitions
an active goal to paused before it is returned.

A separate goal-progress callback reports a snapshot after start/resume and
after every completed autonomous turn. Normal chat streaming and tool callbacks
continue through the existing chat delegate.

### Operations

The session boundary will provide:

- start a new goal with an objective and optional token budget;
- resume a paused goal;
- read the current goal snapshot;
- pause the current goal;
- clear the current goal; and
- reconcile interrupted active goals at app launch.

Start replaces an existing non-running goal for that session. It is rejected
while another chat or goal turn is running. Resume is valid only for `paused`
goals below the engine's turn limit. A goal paused by the runaway guard,
`budgetLimited`, or `complete` requires clear or replacement. Clear cancels an
in-flight goal, removes its durable record, and ends its activity.

Pause and clear must remain callable without waiting for the long-running send
lock. They update durable goal state first and then cancel the current query
scope. This guarantees that a cancellation observed by the runner cannot
accidentally schedule another continuation.

### Goal run

Start performs these steps:

1. Validate and durably create the goal through `GoalStore`.
2. Publish the initial snapshot.
3. Build a goal-only tool registry by taking the ordinary Pocket allowlist and
   adding the explicit-path `GoalCompleteTool`.
4. Use the current session model, account, working directory, system prompt,
   Familiar snapshot, and permission policy unchanged.
5. Persist the user's original `/goal` request as the initiating user turn.
6. Run the existing query loop with the goal system-prompt addendum.
7. Record the turn's cumulative usage and elapsed time through the upstream
   path-scoped continuation API.
8. Publish the resulting snapshot.
9. If continuation is requested, inject the engine-provided continuation
   message and repeat under the same cancellation token and cost tracker.
10. Stop on completion, pause, budget limit, runaway guard, cancellation, or
    explicit error.

Engine-generated continuation prompts are query inputs, not user-authored UI
messages. They remain available to the current model turn but are not rendered
as ordinary composer submissions. Assistant and tool results continue to be
persisted through the existing transcript publication path.

Resume reloads the transcript and durable goal, seeds cumulative accounting
from `Goal.tokens_used`, then begins with the engine-provided continuation
message. It does not create a second initiating user bubble.

The goal runner uses one cancellation token for the complete autonomous run.
It computes the absolute token total as the durable starting total plus usage
recorded by the run's shared `CostTracker`. Per-turn trackers are not used.

### Errors

Objective validation, malformed budgets, invalid transitions, storage errors,
query failures, and progress-write failures are typed FFI errors and become
visible in the in-app goal card. If an error occurs after a goal becomes
active, the runner best-effort transitions it to paused; failure of that
transition is included in the surfaced error rather than swallowed.

Ordinary chat remains usable when the goal store is unavailable, but goal
commands report the storage failure and do not create success-shaped UI state.

## Slash-Command Behavior

A dedicated Swift parser handles exact `/goal` command syntax before ordinary
message submission.

- Leading and trailing whitespace is ignored.
- Command words are ASCII case-sensitive and must match exactly.
- `/goal <objective>` uses no token budget.
- `/goal --tokens <budget> <objective>` requires a positive base-10 `UInt64`
  and a non-empty objective.
- `status`, `pause`, `resume`, and `clear` take no additional arguments.
- Only the exact one-word forms `status`, `pause`, `resume`, and `clear` are
  actions. The same words followed by more objective text are ordinary
  objectives.
- Unknown flags, overflow, missing arguments, and extra action arguments produce
  concise local usage errors and are not sent to the model.

The composer is disabled while a goal is actively running. The existing Stop
control becomes a Pause action for that state. A paused goal does not prevent
ordinary messages, but starting a new goal replaces it only after explicit
command submission.

`/goal status` opens or refreshes the in-app card without adding a transcript
message. Pause, resume, and clear likewise remain control operations rather
than model-visible user messages.

## In-App Goal State

`ChatModel` owns a typed optional goal snapshot for its installed on-device
session. The snapshot is refreshed:

- when a session is installed;
- after every goal callback;
- after pause, resume, clear, or stop;
- after scene-phase expiration handling; and
- after launch reconciliation.

The chat screen shows a compact card above the composer while a goal record
exists. It displays the objective, status, turns, elapsed time, and token usage
with budget progress when applicable. Controls are state-specific:

- active: Pause;
- paused below the turn limit: Resume and Clear;
- paused at the turn limit: Start New Goal and Clear;
- budget-limited: Start New Goal and Clear;
- complete: Clear.

Runtime errors appear in the card without replacing the durable snapshot.
Changing sessions detaches the old card and loads the selected session's goal.
Only the installed on-device session can execute; selecting another session
cannot leave a hidden runner attached to the previous session.

Companion chat does not parse or advertise these local commands.

## iOS Background Execution

The app may continue a goal in the foreground without a special background
claim. When the scene enters the background while a goal is active, the goal
execution coordinator requests one finite `UIApplication` background task.

- If iOS grants the task, execution continues until the goal stops, the app
  returns to the foreground, or expiration fires.
- On expiration, the coordinator durably pauses the goal and then cancels its
  current query.
- If no background task is granted, the coordinator immediately performs the
  same pause-and-cancel sequence.
- The background-task identifier is ended exactly once on foreground return,
  goal termination, or expiration cleanup.

Live Activity updates do not extend this execution window. Pocket will not
register `BGProcessingTask`, start timers intended to evade suspension, or
promise completion while the process is suspended.

If iOS terminates the process before an expiration callback completes, the
durable goal may still say `active`. At the start of the next app launch,
before session interaction is enabled, Pocket reconciles every leftover active
on-device goal to `paused`. The Live Activity manager then ends stale
activities. Resumption always requires an explicit `/goal resume` or Resume
control.

## Live Activity

`project.yml` will define a WidgetKit app-extension target. The generated
`.xcodeproj` remains uncommitted. The main app's Info properties will declare
Live Activity support.

### Shared activity data

The app and extension share a small `GoalActivityAttributes` source file:

- immutable goal ID and session ID; and
- dynamic status, turns used, tokens used, optional token budget, elapsed
  seconds, and update date.

The objective is intentionally excluded from lock-screen and Dynamic Island
content to avoid exposing user-provided text outside the unlocked app. The
in-app card remains the detailed view.

### Presentation

The Lock Screen presentation shows:

- “Goal running”, “Goal paused”, “Budget reached”, or “Goal complete”;
- turns and elapsed time;
- token progress when a budget exists; and
- a compact progress indicator.

The Dynamic Island implementation is deliberately minimal: state in compact
leading, bounded progress in compact trailing, and the same metrics in expanded
regions. It has no approval controls or ordinary-chat content.

### Lifecycle

The manager requests one activity when a goal starts or resumes and updates it
after completed turns. Updates are coalesced so streaming tokens and individual
tool events do not cause ActivityKit churn.

- completion ends with a short final display;
- pause, budget limit, or error ends with a longer attention display;
- clear ends immediately; and
- resume starts a fresh activity.

Failure or denial from ActivityKit is non-fatal: the in-app goal continues and
the card reports that external progress is unavailable only when useful to the
user. ActivityKit errors never change engine goal status.

At launch, the manager enumerates activities created by this attributes type
and ends any whose goal is not currently executing. It does not treat an
activity's content state as evidence that execution is alive.

## Concurrency and Lifecycle Invariants

- At most one query or autonomous goal run can own a `ChatSession`.
- Pause and clear can interrupt that owner without acquiring its long-running
  lock.
- Goal state is persisted before another continuation is scheduled.
- Every goal storage lookup, tool call, transcript operation, callback, and UI
  snapshot uses the same canonical session ID.
- UI state is mutated only on `@MainActor`; UniFFI callbacks hop from Rust
  threads before touching it.
- A session cannot be deleted while installed or running.
- Deletion removes the matching goal; fork never copies it.
- A Familiar snapshot is pinned exactly as it is for ordinary chat and cannot
  change between autonomous turns.
- ActivityKit is an observer, never the owner or source of goal execution.

## Testing Strategy

### Upstream Rust

- Explicit-path continuation never opens the default database.
- Explicit-path `GoalCompleteTool` completes only the matching session.
- Missing goals and zero-row status transitions are errors.
- Completed-turn accounting atomically advances turns, elapsed time, and
  monotonic absolute tokens.
- Budget and runaway decisions use the durable post-turn values.
- Default desktop wrappers retain their existing behavior.

### Pocket Rust

- Command lifecycle methods reject invalid transitions and objective/budget
  errors.
- Start and resume use the canonical chat session ID.
- `GoalComplete` is present only in a goal run.
- Autonomous turns share cancellation and cumulative accounting.
- Continuation inputs are not published as user-authored transcript messages.
- Pause prevents a subsequent continuation even when cancellation races a turn
  completion.
- Runtime failure leaves the goal paused and returns the real error.
- Relaunch reconciliation pauses leftover active goals.
- Session delete and recovery clear goals; fork does not inherit one.
- Goal database and SQLite sidecar symlinks are rejected.

### Swift

- Parser coverage includes all commands, whitespace, reserved words, unknown
  flags, missing objectives, zero, overflow, and extra arguments.
- Rust-thread callbacks update `ChatModel` only through `@MainActor`.
- Goal-card controls map correctly for every status.
- Session switching cannot leave a hidden runner.
- The background coordinator begins and ends one claim, pauses before cancel,
  and handles denial and expiration idempotently.
- Activity state mapping, update coalescing, terminal dismissal, denial, and
  stale-activity cleanup are covered through an injected ActivityKit adapter.

### Integration and release

- Regenerate UniFFI bindings and confirm the generated diff is expected.
- Run Rust tests, check, clippy with warnings denied, and rustfmt check.
- Run targeted Swift tests, then the full simulator test suite.
- Run strict SwiftLint.
- Generate the Xcode project and build both app and WidgetKit extension for a
  generic iOS Simulator destination.
- Manually exercise start, pause, resume, budget stop, completion, background
  expiration, relaunch reconciliation, session switching, and Live Activity
  denial on supported simulator/device environments.

## Acceptance Criteria

1. An on-device Codex session accepts every documented `/goal` form and rejects
   malformed forms locally.
2. A started goal autonomously continues through coven-code decisions until a
   defined stop condition occurs.
3. Tokens, elapsed time, turns, status, and objective persist by canonical
   session ID and survive app restart.
4. Pause and clear stop continuation without waiting for the current run lock;
   resume continues only a paused goal.
5. `GoalComplete` can complete the active Pocket goal and is unavailable during
   ordinary chat.
6. Background expiration durably pauses and cancels the goal; relaunch
   reconciles an abrupt prior termination to paused.
7. The in-app card and privacy-safe Live Activity reflect typed durable
   progress without becoming execution authority.
8. Companion behavior, ordinary chat tools, permissions, model choice,
   Familiar identity, and non-goal session behavior remain unchanged.
9. Session deletion clears its goal, and forks never inherit goals.
10. Upstream coven-code changes are merged and deliberately pinned before the
    Pocket release is opened.
