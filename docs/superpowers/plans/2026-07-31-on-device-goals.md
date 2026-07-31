# On-Device Goals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable on-device `/goal` execution with bounded iOS background continuation, in-app controls, and privacy-safe Live Activity progress.

**Architecture:** First extend coven-code with explicit-path goal persistence, atomic completed-turn accounting, and an explicit-path `GoalCompleteTool`, then merge and deliberately pin that engine revision. Pocket's Rust layer validates an app-owned goal database, drives the upstream continuation state machine under one cancellation/cost scope, and exposes typed UniFFI lifecycle APIs; Swift parses commands, owns main-actor presentation state, pauses at iOS background expiration, and publishes goal-only ActivityKit state.

**Tech Stack:** Rust 2021, rusqlite through `claurst-core`, coven-code query/tools crates, UniFFI 0.32, Swift 5.10/SwiftUI, ActivityKit, WidgetKit, UIKit background tasks, XCTest, XcodeGen, Beads, GitHub CLI.

---

## Scope and Repository Layout

The implementation spans two repositories but one feature:

- Pocket checkout: `/Users/buns/Documents/GitHub/OpenCoven/coven-pocket`
- Upstream checkout: `/Users/buns/Documents/GitHub/OpenCoven/coven-code`
- Design authority:
  `docs/superpowers/specs/2026-07-31-on-device-goals-design.md`
- Pocket Bead: `pocket-hoh`
- GitHub issue: `OpenCoven/coven-pocket#13`

Create an isolated upstream worktree at
`/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path`. Keep Pocket on
`feat/on-device-goals`.

## File Structure

### Upstream coven-code

- Modify `src-rust/crates/core/src/goal.rs`
  - explicit read errors, active-only transitions, atomic completed-turn
    accounting, active-goal reconciliation.
- Modify `src-rust/crates/core/src/lib.rs`
  - retain goal type re-exports.
- Modify `src-rust/crates/query/src/goal_loop.rs`
  - explicit-path continuation API and post-turn budget/runaway decisions.
- Modify `src-rust/crates/query/src/lib.rs`
  - export the path-scoped API.
- Modify `src-rust/crates/tools/src/goal_complete.rs`
  - default and explicit-path store selection.
- Modify `src-rust/crates/tools/src/lib.rs`
  - construct the default tool explicitly in built-in registries.

### Coven Pocket Rust

- Modify `rust/Cargo.toml` and `rust/Cargo.lock`
  - pin the merged upstream revision.
- Create `rust/ffi/src/goals.rs`
  - UniFFI goal types, conversion, durable lifecycle helpers, reconciliation.
- Modify `rust/ffi/src/sessions.rs`
  - checked `goals.sqlite` layout, goal-store adapter, delete/recovery cleanup.
- Modify `rust/ffi/src/chat.rs`
  - canonical tool session IDs, goal-only tools, autonomous runner, pause/clear.
- Modify `rust/ffi/src/lib.rs`
  - exports and engine-wide launch reconciliation.
- Regenerate `app/Sources/Generated/coven_pocket_ffi.swift`
  - generated UniFFI declarations; never edit it manually.

### Coven Pocket Swift and UI

- Create `app/Sources/Support/Goals/GoalCommandParser.swift`
  - pure exact-syntax parser.
- Create `app/Sources/Support/Goals/GoalProgressBridge.swift`
  - Rust-thread to `@MainActor` goal snapshot bridge.
- Create `app/Sources/Support/Goals/GoalExecutionCoordinator.swift`
  - finite UIKit background-task ownership and expiration pause.
- Create `app/Sources/Support/Goals/GoalActivityAttributes.swift`
  - app/widget shared ActivityKit schema.
- Create `app/Sources/Support/Goals/GoalActivityManager.swift`
  - ActivityKit request/update/end/stale cleanup.
- Create `app/Sources/Views/Goals/GoalCardView.swift`
  - typed goal status card and controls.
- Create `app/GoalWidgetExtension/CovenPocketGoalWidgetBundle.swift`
  - WidgetKit extension entry point.
- Create `app/GoalWidgetExtension/GoalLiveActivity.swift`
  - Lock Screen and minimal Dynamic Island presentation.
- Modify `app/Sources/Support/ChatModel.swift`
  - installed-session goal state and command lifecycle.
- Modify `app/Sources/Views/ChatView.swift`
  - command routing, goal card, Pause control, goal-ready send gating.
- Modify `app/Sources/Views/RootView.swift`
  - stable app-scoped goal coordinator ownership for the single supported
    scene.
- Modify `app/Sources/CovenPocketApp.swift`
  - scene-phase delivery and launch preparation.
- Modify `project.yml`
  - Live Activity Info key, widget extension target, embedding, scheme build.

### Tests

- Add upstream tests beside each changed Rust module.
- Add Pocket Rust tests in `goals.rs`, `chat.rs`, and `sessions.rs`.
- Create `app/Tests/GoalCommandParserTests.swift`.
- Create `app/Tests/GoalExecutionCoordinatorTests.swift`.
- Create `app/Tests/GoalActivityManagerTests.swift`.
- Create `app/Tests/GoalChatModelTests.swift`.
- Create `app/Tests/GoalCardViewTests.swift`.

---

### Task 1: Establish durable tracking and the upstream worktree

**Files:**
- Modify: `.beads/issues.jsonl`
- Modify: `.beads/interactions.jsonl`
- Modify: `docs/superpowers/specs/2026-07-31-on-device-goals-design.md`
- Create: `docs/superpowers/plans/2026-07-31-on-device-goals.md`
- Create worktree:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path`

- [ ] **Step 1: Create implementation child Beads**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
bd create --parent pocket-hoh --title "Upstream path-scoped goal APIs" \
  --description "Add explicit-path continuation/completion, atomic progress, and active-goal reconciliation in coven-code; merge before Pocket pin bump." \
  --type task --priority 2 --json
bd create --parent pocket-hoh --title "Pocket on-device goal runtime" \
  --description "Pin upstream, add checked goal storage, typed UniFFI lifecycle, autonomous continuation, and session cleanup integration." \
  --type task --priority 2 --json
bd create --parent pocket-hoh --title "Goal UI and bounded iOS lifecycle" \
  --description "Add slash parser, main-actor model state, background expiry pause, goal card, ActivityKit manager, and WidgetKit extension." \
  --type task --priority 2 --json
bd create --parent pocket-hoh --title "Goal release hardening" \
  --description "Run focused and holistic review loops, immutable release gates, CI, PR merge, and issue closure." \
  --type task --priority 2 --json
```

Expected: four JSON issue records whose IDs are children of `pocket-hoh`.
Record the returned IDs in the parent note with:

```bash
bd update pocket-hoh --append-notes \
  "Implementation split into four child beads: upstream engine boundary, Pocket Rust runtime, Swift/iOS presentation, and release hardening." --json
```

- [ ] **Step 2: Claim the upstream child**

Run `bd list --parent pocket-hoh --json`, identify the child titled
`Upstream path-scoped goal APIs`, then run:

```bash
bd update "$(bd list --parent pocket-hoh --json | jq -r \
  '.[] | select(.title == "Upstream path-scoped goal APIs") | .id')" \
  --claim --json
```

Expected: the child status is `in_progress` with the current user assigned.

- [ ] **Step 3: Create an isolated upstream branch**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code
git fetch origin
git worktree add /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path \
  -b feat/path-scoped-goals origin/main
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path status --short --branch
```

Expected: clean `feat/path-scoped-goals` based on `origin/main`.

- [ ] **Step 4: Commit the approved design, plan, and Pocket tracking**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
git add .beads/issues.jsonl .beads/interactions.jsonl \
  docs/superpowers/specs/2026-07-31-on-device-goals-design.md \
  docs/superpowers/plans/2026-07-31-on-device-goals.md
git commit -m "docs: plan on-device goal implementation"
```

Expected: one planning and tracking commit on `feat/on-device-goals`; the
approved design and execution plan no longer remain as untracked release-gate
residue.

---

### Task 2: Make upstream goal storage explicit and lossless

**Files:**
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/core/src/goal.rs`
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/core/src/lib.rs`

- [ ] **Step 1: Write failing storage regressions**

Add tests to `goal.rs`:

```rust
#[test]
fn missing_goal_mutations_are_errors() {
    let store = open_tmp();
    assert!(matches!(
        store.set_status("missing", GoalStatus::Paused),
        Err(GoalError::NotFound { .. })
    ));
    assert!(matches!(
        store.record_completed_turn("missing", 10, 2),
        Err(GoalError::NotFound { .. })
    ));
}

#[test]
fn completed_turn_records_monotonic_absolute_progress_atomically() {
    let store = open_tmp();
    store.set_goal("sess1", "ship it", Some(1_000)).unwrap();
    store.record_completed_turn("sess1", 700, 11).unwrap();
    store.record_completed_turn("sess1", 650, 7).unwrap();

    let goal = store.try_get_goal("sess1").unwrap().unwrap();
    assert_eq!(goal.tokens_used, 700);
    assert_eq!(goal.time_used_secs, 18);
    assert_eq!(goal.turns_used, 2);
}

#[test]
fn invalid_replacement_budget_preserves_the_existing_goal() {
    let store = open_tmp();
    store.set_goal("sess1", "keep me", None).unwrap();
    let result = store.set_goal("sess1", "replace me", Some(u64::MAX));
    assert!(matches!(
        result,
        Err(GoalError::TokenBudgetTooLarge { .. })
    ));
    assert_eq!(
        store.try_get_goal("sess1").unwrap().unwrap().objective,
        "keep me"
    );
}

#[test]
fn complete_active_goal_rejects_paused_or_missing_goal() {
    let store = open_tmp();
    store.set_goal("sess1", "ship it", None).unwrap();
    store.set_status("sess1", GoalStatus::Paused).unwrap();
    assert!(matches!(
        store.complete_active_goal("sess1"),
        Err(GoalError::NotActive { .. })
    ));
    assert!(matches!(
        store.complete_active_goal("missing"),
        Err(GoalError::NotFound { .. })
    ));
}

#[test]
fn pause_and_resume_are_status_guarded() {
    let store = open_tmp();
    store.set_goal("active", "ship it", None).unwrap();
    store.pause_active_goal("active").unwrap();
    assert_eq!(
        store.try_get_goal("active").unwrap().unwrap().status,
        GoalStatus::Paused
    );
    store.resume_paused_goal("active").unwrap();
    assert_eq!(
        store.try_get_goal("active").unwrap().unwrap().status,
        GoalStatus::Active
    );

    store.complete_active_goal("active").unwrap();
    assert!(matches!(
        store.pause_active_goal("active"),
        Err(GoalError::NotActive { .. })
    ));
    assert!(matches!(
        store.resume_paused_goal("active"),
        Err(GoalError::NotActive { .. })
    ));

    store.set_goal("limited", "ship it", Some(1)).unwrap();
    store.budget_limit_active_goal("limited").unwrap();
    assert_eq!(
        store.try_get_goal("limited").unwrap().unwrap().status,
        GoalStatus::BudgetLimited
    );
    assert!(matches!(
        store.pause_active_goal("limited"),
        Err(GoalError::NotActive { .. })
    ));
}

#[test]
fn pause_active_goals_returns_only_reconciled_rows() {
    let mut store = open_tmp();
    store.set_goal("active", "continue", None).unwrap();
    store.set_goal("complete", "done", None).unwrap();
    store.complete_active_goal("complete").unwrap();

    let paused = store.pause_active_goals().unwrap();
    assert_eq!(paused.len(), 1);
    assert_eq!(paused[0].session_id, "active");
    assert_eq!(paused[0].status, GoalStatus::Paused);
    assert_eq!(
        store.try_get_goal("complete").unwrap().unwrap().status,
        GoalStatus::Complete
    );
}
```

Also change existing direct `get_goal` assertions in new tests to use
`try_get_goal` where error visibility matters.

- [ ] **Step 2: Run the focused tests and confirm red**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-core goal::tests::
```

Expected: compilation fails because the variants and methods do not exist.

- [ ] **Step 3: Add explicit errors and fallible reads**

Implement these variants and helpers in `goal.rs`:

```rust
#[derive(Debug)]
pub enum GoalError {
    ObjectiveEmpty,
    ObjectiveTooLong { len: usize, max: usize },
    TokenBudgetTooLarge { budget: u64, max: u64 },
    NotFound { session_id: String },
    NotActive { session_id: String },
    Db(String),
}
```

Add matching `Display` arms:

```rust
GoalError::ObjectiveEmpty => write!(f, "Goal objective cannot be empty"),
GoalError::TokenBudgetTooLarge { budget, max } => {
    write!(f, "Token budget {budget} exceeds maximum {max}")
}
GoalError::NotFound { session_id } => {
    write!(f, "No goal exists for session {session_id}")
}
GoalError::NotActive { session_id } => {
    write!(f, "No active goal exists for session {session_id}")
}
```

Factor row decoding into one helper and add a non-swallowing read:

```rust
pub fn try_get_goal(&self, session_id: &str) -> Result<Option<Goal>, GoalError> {
    self.conn
        .query_row(
            "SELECT id, session_id, objective, status, token_budget,
                    tokens_used, time_used_secs, turns_used,
                    created_at_ms, updated_at_ms
             FROM goals WHERE session_id = ?1",
            [session_id],
            Self::decode_goal,
        )
        .optional()
        .map_err(|error| GoalError::Db(error.to_string()))
}

pub fn get_goal(&self, session_id: &str) -> Option<Goal> {
    self.try_get_goal(session_id).ok().flatten()
}
```

Import `rusqlite::OptionalExtension`. Reject an empty trimmed objective before
the existing character limit.

- [ ] **Step 4: Implement checked transitions and atomic progress**

Use affected-row checks:

```rust
fn require_updated(session_id: &str, updated: usize) -> Result<(), GoalError> {
    if updated == 0 {
        Err(GoalError::NotFound {
            session_id: session_id.to_string(),
        })
    } else {
        Ok(())
    }
}

pub fn record_completed_turn(
    &self,
    session_id: &str,
    total_tokens_used: u64,
    elapsed_secs: u64,
) -> Result<(), GoalError> {
    let updated = self
        .conn
        .execute(
            "UPDATE goals
             SET tokens_used = MAX(tokens_used, ?1),
                 time_used_secs = time_used_secs + ?2,
                 turns_used = turns_used + 1,
                 updated_at_ms = ?3
             WHERE session_id = ?4",
            rusqlite::params![
                total_tokens_used,
                elapsed_secs,
                Self::now_ms(),
                session_id
            ],
        )
        .map_err(|error| GoalError::Db(error.to_string()))?;
    Self::require_updated(session_id, updated)
}

pub fn complete_active_goal(&self, session_id: &str) -> Result<(), GoalError> {
    let updated = self
        .conn
        .execute(
            "UPDATE goals SET status = 'complete', updated_at_ms = ?1
             WHERE session_id = ?2 AND status = 'active'",
            rusqlite::params![Self::now_ms(), session_id],
        )
        .map_err(|error| GoalError::Db(error.to_string()))?;
    if updated == 1 {
        return Ok(());
    }
    match self.try_get_goal(session_id)? {
        Some(_) => Err(GoalError::NotActive {
            session_id: session_id.to_string(),
        }),
        None => Err(GoalError::NotFound {
            session_id: session_id.to_string(),
        }),
    }
}
```

Make `set_status` reject a missing session with `require_updated`. Keep
`clear_goal` idempotent because deletion recovery calls it repeatedly.
Add status-guarded transitions:

```rust
pub fn pause_active_goal(&self, session_id: &str) -> Result<(), GoalError> {
    let updated = self
        .conn
        .execute(
            "UPDATE goals SET status = 'paused', updated_at_ms = ?1
             WHERE session_id = ?2 AND status = 'active'",
            rusqlite::params![Self::now_ms(), session_id],
        )
        .map_err(|error| GoalError::Db(error.to_string()))?;
    if updated == 1 {
        return Ok(());
    }
    match self.try_get_goal(session_id)? {
        Some(goal) if goal.status == GoalStatus::Paused => Ok(()),
        Some(_) => Err(GoalError::NotActive {
            session_id: session_id.to_string(),
        }),
        None => Err(GoalError::NotFound {
            session_id: session_id.to_string(),
        }),
    }
}

pub fn resume_paused_goal(&self, session_id: &str) -> Result<(), GoalError> {
    let updated = self
        .conn
        .execute(
            "UPDATE goals SET status = 'active', updated_at_ms = ?1
             WHERE session_id = ?2 AND status = 'paused'
               AND turns_used < ?3",
            rusqlite::params![
                Self::now_ms(),
                session_id,
                MAX_GOAL_TURNS
            ],
        )
        .map_err(|error| GoalError::Db(error.to_string()))?;
    if updated == 1 {
        return Ok(());
    }
    match self.try_get_goal(session_id)? {
        Some(_) => Err(GoalError::NotActive {
            session_id: session_id.to_string(),
        }),
        None => Err(GoalError::NotFound {
            session_id: session_id.to_string(),
        }),
    }
}
```

Implement `budget_limit_active_goal` with the same affected-row/status
distinction and `WHERE status = 'active'`. Pocket and the query continuation
path never use generic `set_status` to pause, resume, budget-limit, or complete
a goal.

Before mutating an existing goal in `set_goal`, convert the optional budget
with `i64::try_from`; return `TokenBudgetTooLarge` with `i64::MAX as u64` on
overflow. Make replacement atomic with
`Connection::unchecked_transaction()`: delete and insert inside that
transaction and commit only after the insertion succeeds.

- [ ] **Step 5: Implement launch reconciliation**

Add `list_goals` and a transaction-backed `pause_active_goals`:

```rust
pub fn pause_active_goals(&mut self) -> Result<Vec<Goal>, GoalError> {
    let transaction = self
        .conn
        .transaction()
        .map_err(|error| GoalError::Db(error.to_string()))?;
    let active = Self::query_goals(
        &transaction,
        "SELECT id, session_id, objective, status, token_budget,
                tokens_used, time_used_secs, turns_used,
                created_at_ms, updated_at_ms
         FROM goals WHERE status = 'active' ORDER BY created_at_ms",
    )?;
    let now = Self::now_ms();
    transaction
        .execute(
            "UPDATE goals SET status = 'paused', updated_at_ms = ?1
             WHERE status = 'active'",
            [now],
        )
        .map_err(|error| GoalError::Db(error.to_string()))?;
    transaction
        .commit()
        .map_err(|error| GoalError::Db(error.to_string()))?;
    Ok(active
        .into_iter()
        .map(|mut goal| {
            goal.status = GoalStatus::Paused;
            goal.updated_at_ms = now;
            goal
        })
        .collect())
}
```

The shared `query_goals` helper must propagate row conversion errors instead of
dropping rows.

- [ ] **Step 6: Run core goal tests**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-core goal::
```

Expected: all goal tests pass.

- [ ] **Step 7: Commit the storage boundary**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path add \
  src-rust/crates/core/src/goal.rs src-rust/crates/core/src/lib.rs
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path commit \
  -m "fix: make goal progress durable and explicit"
```

Expected: one focused upstream core commit.

---

### Task 3: Add path-scoped upstream continuation

**Files:**
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/query/src/goal_loop.rs`
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/query/src/lib.rs`
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/cli/src/main.rs`
- Modify as required for the additive event:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/cli/src/stream_mode.rs`
- Modify as required for the additive event:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/acp/src/prompt.rs`
- Modify as required for the additive event:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/tui/src/app.rs`
- Modify as required for the additive event:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/tui/src/lib.rs`

- [ ] **Step 1: Write failing continuation tests**

Add a `#[cfg(test)]` module to `goal_loop.rs`:

```rust
fn goal_path(dir: &tempfile::TempDir) -> PathBuf {
    dir.path().join("goals.sqlite")
}

#[test]
fn explicit_path_records_progress_before_budget_stop() {
    let dir = tempfile::tempdir().unwrap();
    let path = goal_path(&dir);
    GoalStore::open(&path)
        .unwrap()
        .set_goal("session", "finish", Some(100))
        .unwrap();

    let decision =
        check_and_continue_goal_at_path(&path, "session", 100, 9).unwrap();
    assert!(matches!(
        decision,
        GoalContinuation::Stop {
            reason: StopReason::BudgetLimited
        }
    ));
    let goal = GoalStore::open(&path)
        .unwrap()
        .try_get_goal("session")
        .unwrap()
        .unwrap();
    assert_eq!(goal.tokens_used, 100);
    assert_eq!(goal.time_used_secs, 9);
    assert_eq!(goal.turns_used, 1);
}

#[test]
fn explicit_path_stops_at_the_recorded_runaway_boundary() {
    let dir = tempfile::tempdir().unwrap();
    let path = goal_path(&dir);
    let store = GoalStore::open(&path).unwrap();
    store.set_goal("session", "finish", None).unwrap();
    for turn in 1..MAX_GOAL_TURNS {
        store
            .record_completed_turn("session", u64::from(turn), 1)
            .unwrap();
    }

    let decision =
        check_and_continue_goal_at_path(&path, "session", 999, 1).unwrap();
    assert!(matches!(
        decision,
        GoalContinuation::Stop {
            reason: StopReason::RunawayGuard {
                turns_used: MAX_GOAL_TURNS
            }
        }
    ));
}

#[test]
fn explicit_path_reports_missing_goal() {
    let dir = tempfile::tempdir().unwrap();
    let error =
        check_and_continue_goal_at_path(&goal_path(&dir), "missing", 0, 0)
            .unwrap_err();
    assert!(matches!(error, GoalError::NotFound { .. }));
}
```

Import `std::path::{Path, PathBuf}` in production/tests as needed.

- [ ] **Step 2: Confirm the query tests fail**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-query goal_loop::tests::
```

Expected: compilation fails because `check_and_continue_goal_at_path` is absent.

- [ ] **Step 3: Factor one store-driven decision function**

Implement:

```rust
fn check_and_continue_goal_in_store(
    store: &GoalStore,
    session_id: &str,
    total_tokens_used: u64,
    turn_elapsed_secs: u64,
) -> Result<GoalContinuation, GoalError> {
    store.record_completed_turn(
        session_id,
        total_tokens_used,
        turn_elapsed_secs,
    )?;
    let goal = store
        .try_get_goal(session_id)?
        .ok_or_else(|| GoalError::NotFound {
            session_id: session_id.to_string(),
        })?;

    match goal.status {
        GoalStatus::Complete => {
            return Ok(GoalContinuation::Stop {
                reason: StopReason::GoalComplete,
            });
        }
        GoalStatus::Paused => {
            return Ok(GoalContinuation::Stop {
                reason: StopReason::Paused,
            });
        }
        GoalStatus::BudgetLimited => {
            return Ok(GoalContinuation::Stop {
                reason: StopReason::BudgetLimited,
            });
        }
        GoalStatus::Active => {}
    }

    if goal.turns_used >= MAX_GOAL_TURNS {
        store.pause_active_goal(session_id)?;
        return Ok(GoalContinuation::Stop {
            reason: StopReason::RunawayGuard {
                turns_used: goal.turns_used,
            },
        });
    }
    if goal.is_over_budget(goal.tokens_used) {
        store.budget_limit_active_goal(session_id)?;
        return Ok(GoalContinuation::Stop {
            reason: StopReason::BudgetLimited,
        });
    }
    Ok(GoalContinuation::Continue {
        message: goal_continuation_message(&goal),
    })
}

pub fn check_and_continue_goal_at_path(
    goal_db_path: &Path,
    session_id: &str,
    total_tokens_used: u64,
    turn_elapsed_secs: u64,
) -> Result<GoalContinuation, GoalError> {
    let store = GoalStore::open(goal_db_path)?;
    check_and_continue_goal_in_store(
        &store,
        session_id,
        total_tokens_used,
        turn_elapsed_secs,
    )
}
```

Keep `check_and_continue_goal` as the compatibility wrapper. It opens the
default store, maps `NotFound` to `NoGoal`, and maps other failures to
`StopReason::Error`; no explicit-path error is swallowed.
Derive `Debug` for `GoalContinuation` so path-scoped `Result` failures remain
straightforward to assert and diagnose.
Change the default-path `mark_goal_complete` helper to call
`complete_active_goal`, so every completion route enforces the same active-only
transition.

For the guarded runaway and budget transitions, handle a racing
`GoalError::NotActive` by reloading the goal and returning its actual terminal
decision:

```rust
fn stop_for_terminal_status(goal: &Goal) -> Option<GoalContinuation> {
    let reason = match goal.status {
        GoalStatus::Complete => StopReason::GoalComplete,
        GoalStatus::Paused => StopReason::Paused,
        GoalStatus::BudgetLimited => StopReason::BudgetLimited,
        GoalStatus::Active => return None,
    };
    Some(GoalContinuation::Stop { reason })
}
```

If reload still shows active, return the original transition error. A missing
goal remains `GoalError::NotFound` for the explicit-path caller. This makes a
concurrent user pause or model completion win without rewriting terminal state.

- [ ] **Step 4: Correct terminal user messages**

Change budget and runaway text so they do not suggest an invalid resume:

```rust
StopReason::BudgetLimited => Some(
    "Soft token budget reached — goal paused. Start a new goal with a new budget."
        .to_string(),
),
StopReason::RunawayGuard { turns_used } => Some(format!(
    "Goal paused after {} turns (runaway guard). Start a new goal to continue.",
    turns_used
)),
```

Remove `mark_goal_complete_at_path`; completion remains a core-store operation
used directly by `GoalCompleteTool`, avoiding a tools-to-query dependency cycle.

- [ ] **Step 5: Emit a compaction-safe durable-message journal**

Add to `QueryEvent`:

```rust
DurableMessage {
    message: Message,
},
```

Factor finalized-message publication:

```rust
fn emit_durable_message(
    event_tx: Option<&mpsc::UnboundedSender<QueryEvent>>,
    message: &Message,
) {
    if let Some(tx) = event_tx {
        let _ = tx.send(QueryEvent::DurableMessage {
            message: message.clone(),
        });
    }
}
```

Keep normal `messages.push` behavior. Emit an assistant message only after all
placeholder text, snapshot patch, and other branch-specific finalization is
complete and immediately before that message becomes an immutable transcript
fact: before tool-result execution/continuation, before a recovery nudge, or
before returning a terminal outcome. When a tool-result carrier is built,
store it in a local variable, push it, then emit that exact clone. Do not emit
queue injections, hook diagnostics, stall nudges, max-token recovery nudges, or
other engine-generated control prompts.

For the non-Anthropic provider branch specifically:

- emit the tool-use assistant immediately before tool execution;
- emit the constructed tool-result carrier immediately after pushing it;
- emit each finalized assistant immediately before a stall/max-token recovery
  nudge;
- on terminal end-turn/stop branches, add any empty-response placeholder and
  snapshot patch first, then emit exactly once immediately before return.

Apply the same semantic points to the Anthropic branch: emit finalized
assistants before tool execution, recovery continuation, or each terminal
return, and emit the exact constructed tool-result carrier once after pushing
it. Update the stored working-history clone when finalization mutates a message
after its initial push so working history and the durable event agree.

Add a Tokio test that receives the event, then replaces the caller's message
vector to simulate both finalization and compaction and proves the durable
event contains the final assistant message:

```rust
#[tokio::test]
async fn durable_message_event_survives_context_rewrite() {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let mut assistant = Message::assistant("");
    let mut messages = vec![assistant.clone()];
    assistant = Message::assistant("final placeholder");
    messages[0] = assistant.clone();
    emit_durable_message(Some(&tx), &assistant);
    messages = vec![Message::user("compacted summary")];

    let event = rx.recv().await.unwrap();
    match event {
        QueryEvent::DurableMessage { message } => {
            assert_eq!(message.get_all_text(), "final placeholder")
        }
        _ => panic!("expected durable message event"),
    }
    assert_eq!(messages.len(), 1);
}
```

Also add a query-loop integration regression in `query/src/lib.rs`:

```rust
#[tokio::test]
async fn provider_dispatch_emits_finalized_durable_messages_exactly_once() {
    // A scripted non-Anthropic provider returns:
    // 1. one tool-use round;
    // 2. two empty end-turn rounds consumed by bounded stall recovery; and
    // 3. one final empty end-turn round.
    //
    // A test tool writes fixture.txt during round 1. Run the real query loop
    // in a temporary git worktree with auto_commits enabled, collect only
    // DurableMessage events, and assert the exact sequence below.
    assert_eq!(durable.len(), 5);
    assert_eq!(assistant_ids(&durable), [
        "tool-round",
        "stall-round-1",
        "stall-round-2",
        "final-round",
    ]);
    assert!(is_tool_use_assistant(&durable[0]));
    assert!(is_tool_result_carrier(&durable[1]));
    assert_eq!(durable[2].get_all_text(), "");
    assert_eq!(durable[3].get_all_text(), "");
    assert_eq!(
        durable[4].get_all_text(),
        "(no response — model ended the turn with stop_reason \"end_turn\")"
    );
    assert!(durable[4].snapshot_patch.is_some());
    assert_eq!(unique_message_fingerprints(&durable).len(), durable.len());
}
```

Implement a test-only `ScriptedProvider: LlmProvider` backed by a
`Mutex<VecDeque<Vec<StreamEvent>>>` and a test-only `WriteFixtureTool` that
writes through `ToolContext.working_dir`. Register the provider under a unique
non-Anthropic ID, set that ID in the test `ToolContext`, initialize and seed a
temporary git repository before invoking the loop, and enable
`config.auto_commits`. Construct complete provider streams with
`MessageStart`, content/tool deltas, `MessageDelta`, and `MessageStop`.
Use distinct provider message IDs so duplicates are observable. Do not disable
stall recovery through process-global environment variables.

This regression must exercise `run_query_loop`, not only
`emit_durable_message`; it must fail if the terminal assistant event moves
back to the initial `messages.push`, because the captured event would have
empty text and no snapshot patch. It also locks one event per tool-use
assistant, tool-result carrier, recovered assistant round, and terminal
assistant.

This journal is additive API behavior; existing callers may ignore the new
event. Update exhaustive event matches in coven-code so the workspace compiles.

- [ ] **Step 6: Export and run query tests**

Export the new function from `query/src/lib.rs`:

```rust
pub use goal_loop::{
    check_and_continue_goal, check_and_continue_goal_at_path,
    mark_goal_complete, GoalContinuation, StopReason,
};
```

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-query goal_loop::
cargo test -p claurst-query durable_message_event_survives_context_rewrite
cargo test -p claurst-query provider_dispatch_emits_finalized_durable_messages_exactly_once
```

Expected: all goal-loop tests pass.

- [ ] **Step 7: Commit path-scoped continuation**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path add \
  src-rust/crates/query/src/goal_loop.rs src-rust/crates/query/src/lib.rs \
  src-rust/crates/cli/src/main.rs src-rust/crates/cli/src/stream_mode.rs \
  src-rust/crates/acp/src/prompt.rs src-rust/crates/tui/src/app.rs \
  src-rust/crates/tui/src/lib.rs
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path commit \
  -m "feat: expose path-scoped goal continuation"
```

---

### Task 4: Make `GoalCompleteTool` path-scoped and active-only

**Files:**
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/tools/src/goal_complete.rs`
- Modify:
  `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/tools/src/lib.rs`

- [ ] **Step 1: Write failing tool tests**

Add tests in `goal_complete.rs` using a local `ToolContext` helper:

```rust
#[tokio::test]
async fn explicit_path_completes_only_the_matching_active_goal() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("goals.sqlite");
    let store = claurst_core::GoalStore::open(&path).unwrap();
    store.set_goal("target", "finish", None).unwrap();
    store.set_goal("other", "stay active", None).unwrap();

    let result = GoalCompleteTool::at_path(path.clone())
        .execute(
            serde_json::json!({
                "audit_summary": "finished",
                "evidence": "tests passed"
            }),
            &test_tool_context("target"),
        )
        .await;
    assert!(!result.is_error);
    let reopened = claurst_core::GoalStore::open(&path).unwrap();
    assert_eq!(
        reopened.try_get_goal("target").unwrap().unwrap().status,
        claurst_core::GoalStatus::Complete
    );
    assert_eq!(
        reopened.try_get_goal("other").unwrap().unwrap().status,
        claurst_core::GoalStatus::Active
    );
}

#[tokio::test]
async fn explicit_path_rejects_paused_and_missing_goals() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("goals.sqlite");
    let store = claurst_core::GoalStore::open(&path).unwrap();
    store.set_goal("paused", "finish", None).unwrap();
    store
        .set_status("paused", claurst_core::GoalStatus::Paused)
        .unwrap();
    let input = serde_json::json!({
        "audit_summary": "finished",
        "evidence": "tests passed"
    });

    assert!(
        GoalCompleteTool::at_path(path.clone())
            .execute(input.clone(), &test_tool_context("paused"))
            .await
            .is_error
    );
    assert!(
        GoalCompleteTool::at_path(path)
            .execute(input, &test_tool_context("missing"))
            .await
            .is_error
    );
}
```

The helper builds the same minimal `ToolContext` shape used by
`tools/src/lib.rs` tests and accepts the session ID as an argument.

- [ ] **Step 2: Confirm the tool tests fail**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-tools goal_complete::tests::
```

Expected: compilation fails because `at_path` does not exist.

- [ ] **Step 3: Add default and explicit store selection**

Implement:

```rust
use std::path::PathBuf;

#[derive(Default)]
pub struct GoalCompleteTool {
    goal_store_path: Option<PathBuf>,
}

impl GoalCompleteTool {
    pub fn at_path(goal_store_path: PathBuf) -> Self {
        Self {
            goal_store_path: Some(goal_store_path),
        }
    }

    fn open_store(&self) -> Result<claurst_core::GoalStore, String> {
        match &self.goal_store_path {
            Some(path) => claurst_core::GoalStore::open(path),
            None => claurst_core::GoalStore::open(
                &claurst_core::GoalStore::default_path(),
            ),
        }
        .map_err(|error| error.to_string())
    }
}
```

Replace `open_default` and generic `set_status` in `execute` with:

```rust
match self.open_store().and_then(|store| {
    store
        .complete_active_goal(session_id)
        .map_err(|error| error.to_string())
}) {
    Ok(()) => ToolResult::success(format!(
        "Goal marked complete.\n\nAudit summary: {}\n\nEvidence: {}",
        params.audit_summary, params.evidence,
    )),
    Err(error) => ToolResult::error(format!(
        "Failed to mark goal complete: {error}"
    )),
}
```

- [ ] **Step 4: Preserve built-in registry behavior**

Replace both unit-struct constructions in `tools/src/lib.rs`:

```rust
Box::new(GoalCompleteTool::default())
```

Keep `all_tool_names()` unchanged.

- [ ] **Step 5: Run tool and registry tests**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-tools goal_complete::
cargo test -p claurst-tools tests::test_all_tool_names_match_all_tools -- --exact
```

Expected: both commands pass.

- [ ] **Step 6: Commit the explicit completion tool**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path add \
  src-rust/crates/tools/src/goal_complete.rs src-rust/crates/tools/src/lib.rs
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path commit \
  -m "feat: scope goal completion to an explicit store"
```

---

### Task 5: Validate, review, merge, and record the upstream boundary

**Files:**
- Modify: Pocket Beads export after upstream merge

- [ ] **Step 1: Run upstream quality gates**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust
cargo test -p claurst-core goal::
cargo test -p claurst-query goal_loop::
cargo test -p claurst-query durable_message_event_survives_context_rewrite
cargo test -p claurst-query provider_dispatch_emits_finalized_durable_messages_exactly_once
cargo test -p claurst-tools goal_complete::
cargo check --workspace
cargo clippy -p claurst-core -p claurst-query -p claurst-tools \
  --all-targets -- -D warnings
cargo fmt --all --check
```

Expected: every command exits zero.

- [ ] **Step 2: Run a focused fresh-context code review**

Invoke the code-review workflow against
`origin/main...feat/path-scoped-goals`. Fix every Critical or Important finding
with a failing regression first, rerun the focused gates, and commit each
coherent correction with the required co-author trailer.

- [ ] **Step 3: Push and open the upstream PR**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path
git push -u origin feat/path-scoped-goals
UPSTREAM_PR=$(gh pr create --repo OpenCoven/coven-code \
  --base main --head feat/path-scoped-goals \
  --title "Expose path-scoped goal execution" \
  --body "$(cat <<'BODY'
## Summary
- add explicit-path goal continuation and completion
- atomically persist completed-turn tokens, elapsed time, and turn count
- make missing/inactive transitions explicit and reconcile interrupted goals

## Validation
- focused core/query/tools tests
- cargo check and clippy with warnings denied
- rustfmt check

Required by OpenCoven/coven-pocket#13.
BODY
)")
printf '%s\n' "$UPSTREAM_PR"
```

Expected: a new `OpenCoven/coven-code` PR URL.

- [ ] **Step 4: Wait for CI and merge**

Run:

```bash
gh pr checks "$UPSTREAM_PR" --watch
gh pr merge "$UPSTREAM_PR" --repo OpenCoven/coven-code \
  --squash --delete-branch
UPSTREAM_REV=$(gh pr view "$UPSTREAM_PR" --repo OpenCoven/coven-code \
  --json mergeCommit --jq '.mergeCommit.oid')
test -n "$UPSTREAM_REV"
printf '%s\n' "$UPSTREAM_REV"
```

Expected: all checks pass and `UPSTREAM_REV` is the 40-character merged commit.

- [ ] **Step 5: Close the upstream child Bead**

Run from Pocket:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
UPSTREAM_PR_NUMBER=$(gh pr list --repo OpenCoven/coven-code \
  --state merged --head feat/path-scoped-goals \
  --json number --jq '.[0].number')
UPSTREAM_REV=$(gh pr view "$UPSTREAM_PR_NUMBER" --repo OpenCoven/coven-code \
  --json mergeCommit --jq '.mergeCommit.oid')
UPSTREAM_BEAD=$(bd list --parent pocket-hoh --json | jq -r \
  '.[] | select(.title == "Upstream path-scoped goal APIs") | .id')
bd close "$UPSTREAM_BEAD" --reason \
  "Merged OpenCoven/coven-code#${UPSTREAM_PR_NUMBER} at ${UPSTREAM_REV}; focused tests, check, clippy, fmt, review, and CI passed." --json
```

Expected: the upstream child is closed with merge evidence.

---

### Task 6: Pin the merged engine revision

**Files:**
- Modify: `rust/Cargo.toml`
- Modify: `rust/Cargo.lock`

- [ ] **Step 1: Resolve the immutable merged revision**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
UPSTREAM_PR_NUMBER=$(gh pr list --repo OpenCoven/coven-code \
  --state merged --head feat/path-scoped-goals \
  --json number --jq '.[0].number')
UPSTREAM_REV=$(gh pr view "$UPSTREAM_PR_NUMBER" --repo OpenCoven/coven-code \
  --json mergeCommit --jq '.mergeCommit.oid')
test "$(printf '%s' "$UPSTREAM_REV" | wc -c | tr -d ' ')" = "40"
```

Expected: the length assertion passes.

- [ ] **Step 2: Update every coven-code workspace dependency**

Run:

```bash
perl -0pi -e "s/rev = \"[0-9a-f]{40}\"/rev = \"$UPSTREAM_REV\"/g" rust/Cargo.toml
cd rust
cargo update -p claurst-core -p claurst-api -p claurst-query -p claurst-tools
```

Expected: all four `rust/Cargo.toml` entries use the same merged revision and
`Cargo.lock` resolves coven-code packages from it.

- [ ] **Step 3: Verify only the intended engine source changed**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
rg -n 'OpenCoven/coven-code|rev = ' rust/Cargo.toml rust/Cargo.lock
cargo check --manifest-path rust/Cargo.toml -p coven-pocket-ffi
```

Expected: one revision is used consistently and the FFI crate checks.

- [ ] **Step 4: Commit the deliberate pin**

Run:

```bash
git add rust/Cargo.toml rust/Cargo.lock .beads/issues.jsonl .beads/interactions.jsonl
git commit -m "build: pin path-scoped goal engine APIs" \
  -m "Pin the merged coven-code goal persistence, continuation, and completion boundary required by on-device goals."
```

---

### Task 7: Add checked Pocket goal storage

**Files:**
- Modify: `rust/ffi/src/sessions.rs`
- Test: `rust/ffi/src/sessions.rs`

- [ ] **Step 1: Write failing goal-store path tests**

Add:

```rust
#[test]
fn checked_goal_storage_uses_one_fixed_database() {
    let storage = test_storage("goal-storage-path");
    let checked = GoalStorage::open(&storage.to_string_lossy()).unwrap();
    assert_eq!(checked.path().unwrap(), storage.join("goals.sqlite"));
}

#[cfg(unix)]
#[test]
fn goal_database_symlink_is_rejected_before_open() {
    use std::os::unix::fs::symlink;
    let storage = test_storage("goal-db-symlink");
    std::fs::create_dir_all(&storage).unwrap();
    let outside = test_storage("goal-db-symlink-outside").join("outside.sqlite");
    std::fs::create_dir_all(outside.parent().unwrap()).unwrap();
    std::fs::write(&outside, b"outside").unwrap();
    symlink(&outside, storage.join("goals.sqlite")).unwrap();

    assert!(
        CheckedStorage::from_root(&storage).is_ok(),
        "invalid goal storage must not disable ordinary session storage"
    );
    assert!(GoalStorage::open(&storage.to_string_lossy()).is_err());
    assert_eq!(std::fs::read(&outside).unwrap(), b"outside");
}

#[cfg(unix)]
#[test]
fn goal_sqlite_sidecar_symlinks_are_rejected() {
    use std::os::unix::fs::symlink;
    for suffix in ["-wal", "-shm", "-journal"] {
        let storage = test_storage(&format!("goal-sidecar{suffix}"));
        std::fs::create_dir_all(&storage).unwrap();
        let outside = storage.parent().unwrap().join(format!("outside{suffix}"));
        std::fs::write(&outside, b"outside").unwrap();
        symlink(&outside, storage.join(format!("goals.sqlite{suffix}"))).unwrap();
        assert!(GoalStorage::open(&storage.to_string_lossy()).is_err());
    }
}
```

- [ ] **Step 2: Confirm the storage tests fail**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi \
  sessions::tests::checked_goal_storage_uses_one_fixed_database
cargo test -p coven-pocket-ffi \
  sessions::tests::goal_database_symlink_is_rejected_before_open
cargo test -p coven-pocket-ffi \
  sessions::tests::goal_sqlite_sidecar_symlinks_are_rejected
```

Expected: compilation fails because `GoalStorage` is absent.

- [ ] **Step 3: Generalize checked SQLite layout**

Add to `CheckedStorage`:

```rust
fn sqlite_file(&self, stem: &str, suffix: &str) -> Result<PathBuf, PocketError> {
    self.child_path(&self.root, &format!("{stem}.sqlite{suffix}"))
}

fn validate_sqlite_family(&self, stem: &str) -> Result<(), PocketError> {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        self.validate_regular_file(&self.sqlite_file(stem, suffix)?, true)?;
    }
    Ok(())
}
```

Keep `validate_sqlite_files()` as the index-specific compatibility helper:

```rust
fn validate_sqlite_files(&self) -> Result<(), PocketError> {
    self.validate_sqlite_family("index")
}
```

Do not add the goal family to `validate_fixed_layout()`: ordinary session
start/resume/list must remain usable when goal storage is invalid. Only
`GoalStorage::open`, goal commands, and session cleanup that must remove a goal
validate the goal SQLite family.

- [ ] **Step 4: Add a cloneable checked goal-store adapter**

Implement in `sessions.rs`:

```rust
#[derive(Clone)]
pub(crate) struct GoalStorage {
    storage: CheckedStorage,
}

impl GoalStorage {
    pub(crate) fn open(storage_dir: &str) -> Result<Self, PocketError> {
        let storage = CheckedStorage::open(storage_dir)?;
        storage.validate_sqlite_family("goals")?;
        Ok(Self { storage })
    }

    pub(crate) fn path(&self) -> Result<PathBuf, PocketError> {
        self.storage.sqlite_file("goals", "")
    }

    pub(crate) fn validate(&self) -> Result<(), PocketError> {
        self.storage.validate_sqlite_family("goals")
    }

    pub(crate) fn with_path<T>(
        &self,
        operation: impl FnOnce(
            &Path,
        ) -> Result<T, claurst_core::GoalError>,
    ) -> Result<T, PocketError> {
        self.storage.validate_sqlite_family("goals")?;
        let path = self.path()?;
        let result = operation(&path)
            .map_err(|error| engine_err("goal store operation failed", error));
        self.storage.validate_sqlite_family("goals")?;
        result
    }

    pub(crate) fn with_store<T>(
        &self,
        operation: impl FnOnce(
            &mut claurst_core::GoalStore,
        ) -> Result<T, claurst_core::GoalError>,
    ) -> Result<T, PocketError> {
        self.with_path(|path| {
            let mut store = claurst_core::GoalStore::open(path)?;
            operation(&mut store)
        })
    }
}
```

Expose `SessionPersistence::goal_storage()` as a clone of this adapter.

- [ ] **Step 5: Run storage tests and existing index symlink tests**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi sessions::tests::checked_goal_storage_uses_one_fixed_database
cargo test -p coven-pocket-ffi sessions::tests::goal_database_symlink_is_rejected_before_open
cargo test -p coven-pocket-ffi sessions::tests::goal_sqlite_sidecar_symlinks_are_rejected
cargo test -p coven-pocket-ffi sessions::tests::index_wal_symlink_is_rejected_before_sqlite_open
cargo test -p coven-pocket-ffi sessions::tests::index_shm_symlink_is_rejected_before_sqlite_open
```

Expected: all pass.

- [ ] **Step 6: Commit checked goal storage**

Run:

```bash
git add rust/ffi/src/sessions.rs
git commit -m "feat: add checked on-device goal storage"
```

---

### Task 8: Expose typed goal lifecycle through UniFFI

**Files:**
- Create: `rust/ffi/src/goals.rs`
- Modify: `rust/ffi/src/lib.rs`
- Modify: `rust/ffi/src/chat.rs`
- Test: `rust/ffi/src/goals.rs`

- [ ] **Step 1: Write failing lifecycle tests**

In the new module, start with tests for conversion and transitions:

```rust
#[test]
fn snapshot_preserves_engine_goal_fields() {
    let goal = engine_goal(GoalStatus::Active, 4, 900, Some(1_000));
    let snapshot = GoalSnapshot::from(goal);
    assert_eq!(snapshot.status, PocketGoalStatus::Active);
    assert_eq!(snapshot.turns_used, 4);
    assert_eq!(snapshot.tokens_used, 900);
    assert_eq!(snapshot.token_budget, Some(1_000));
}

#[test]
fn resume_rejects_terminal_and_runaway_goals() {
    assert!(validate_resume(&engine_goal(
        GoalStatus::BudgetLimited,
        2,
        100,
        Some(100)
    ))
    .is_err());
    assert!(validate_resume(&engine_goal(
        GoalStatus::Paused,
        claurst_core::MAX_GOAL_TURNS,
        100,
        None
    ))
    .is_err());
}

#[tokio::test]
async fn resume_durably_reactivates_a_paused_goal() {
    let storage = test_goal_storage("resume");
    storage
        .with_store(|store| {
            store.set_goal("session", "finish", None)?;
            store.pause_active_goal("session")
        })
        .unwrap();
    let snapshot = resume(storage, "session".to_string()).await.unwrap();
    assert_eq!(snapshot.status, PocketGoalStatus::Active);
}

#[tokio::test]
async fn reconcile_pauses_every_interrupted_active_goal() {
    let storage = test_goal_storage("reconcile");
    storage
        .with_store(|store| {
            store.set_goal("first", "one", None)?;
            store.set_goal("second", "two", None)?;
            Ok(())
        })
        .unwrap();
    let snapshots = reconcile(storage).await.unwrap();
    assert_eq!(snapshots.len(), 2);
    assert!(snapshots
        .iter()
        .all(|snapshot| snapshot.status == PocketGoalStatus::Paused));
}
```

- [ ] **Step 2: Confirm the new module is red**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi goals::
```

Expected: compilation fails until the module and types are implemented/exported.

- [ ] **Step 3: Define the exact UniFFI types**

Implement:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PocketGoalStatus {
    Active,
    Paused,
    BudgetLimited,
    Complete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GoalRunStopReason {
    Complete,
    Paused,
    BudgetLimited,
    RunawayGuard,
    Cleared,
    Cancelled,
    RuntimeError,
    StorageError,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct GoalSnapshot {
    pub goal_id: String,
    pub session_id: String,
    pub objective: String,
    pub status: PocketGoalStatus,
    pub token_budget: Option<u64>,
    pub tokens_used: u64,
    pub elapsed_seconds: u64,
    pub turns_used: u32,
    pub max_turns: u32,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct GoalRunResult {
    pub reason: GoalRunStopReason,
    pub snapshot: Option<GoalSnapshot>,
    pub error_message: Option<String>,
}

#[uniffi::export(with_foreign)]
pub trait GoalProgressDelegate: Send + Sync {
    fn on_goal_snapshot(&self, snapshot: GoalSnapshot);
}
```

Implement `From<claurst_core::Goal>` without lossy casts and set
`max_turns` from `claurst_core::MAX_GOAL_TURNS`, so Swift never duplicates the
engine limit.
`RuntimeError` covers provider/query failures after the durable goal starts;
`StorageError` covers transcript or goal-store failures after start. Validation,
objective, budget, and initial goal-create failures still throw `PocketError`
because no run was established.

- [ ] **Step 4: Add durable helper operations**

Implement helpers that run blocking SQLite work on Tokio's blocking pool:

```rust
pub(crate) async fn load(
    storage: GoalStorage,
    session_id: String,
) -> Result<Option<GoalSnapshot>, PocketError>;

pub(crate) async fn create(
    storage: GoalStorage,
    session_id: String,
    objective: String,
    token_budget: Option<u64>,
) -> Result<GoalSnapshot, PocketError>;

pub(crate) async fn pause(
    storage: GoalStorage,
    session_id: String,
) -> Result<GoalSnapshot, PocketError>;

pub(crate) async fn resume(
    storage: GoalStorage,
    session_id: String,
) -> Result<GoalSnapshot, PocketError>;

pub(crate) async fn clear(
    storage: GoalStorage,
    session_id: String,
) -> Result<(), PocketError>;

pub(crate) async fn reconcile(
    storage: GoalStorage,
) -> Result<Vec<GoalSnapshot>, PocketError>;

pub(crate) async fn continue_after_turn(
    storage: GoalStorage,
    session_id: String,
    total_tokens_used: u64,
    elapsed_seconds: u64,
) -> Result<claurst_query::GoalContinuation, PocketError>;
```

Validate `objective.trim()` is non-empty and `token_budget != Some(0)` before
calling the engine. `validate_resume` accepts only `Paused` with
`turns_used < MAX_GOAL_TURNS`.
Every helper uses `tokio::task::spawn_blocking`; `continue_after_turn` calls
`GoalStorage::validate`, obtains `GoalStorage::path`, calls
`claurst_query::check_and_continue_goal_at_path`, and validates again inside
that blocking closure. It maps only `GoalError::NotFound` to
`GoalContinuation::NoGoal` because concurrent `clear_goal` is a defined stop;
all other engine/storage errors remain failures.
`pause` calls `GoalStore::pause_active_goal`; if a racing call already left the
goal paused it returns that snapshot, but it never rewrites complete or
budget-limited state. `resume` validates, calls
`GoalStore::resume_paused_goal`, reloads the now-active goal in the same
blocking operation, and returns the active snapshot.

- [ ] **Step 5: Export engine reconciliation**

Add `mod goals` and re-exports in `lib.rs`:

```rust
pub use goals::{
    GoalProgressDelegate, GoalRunResult, GoalRunStopReason, GoalSnapshot,
    PocketGoalStatus,
};
```

Add:

```rust
pub async fn reconcile_goals(
    &self,
    storage_dir: String,
) -> Result<Vec<GoalSnapshot>, PocketError> {
    goals::reconcile(sessions::GoalStorage::open(&storage_dir)?).await
}
```

- [ ] **Step 6: Add status, pause, and clear methods to `ChatSession`**

Use `self.persistence.as_ref().map(SessionPersistence::goal_storage)` and
return an explicit error for an in-memory session:

```rust
pub async fn goal_status(&self) -> Result<Option<GoalSnapshot>, PocketError>;
pub async fn pause_goal(&self) -> Result<GoalSnapshot, PocketError>;
pub async fn clear_goal(&self) -> Result<(), PocketError>;
```

`pause_goal` writes `Paused` before `self.stop()`. `clear_goal` removes the goal
before `self.stop()`. Neither acquires the message mutex or waits for `busy`.

- [ ] **Step 7: Run lifecycle tests**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi goals::
cargo test -p coven-pocket-ffi chat::tests::stop_while_persisting_cancels_before_loop_setup -- --exact
```

Expected: all pass and existing cancellation behavior is unchanged.

- [ ] **Step 8: Commit the typed lifecycle**

Run:

```bash
git add rust/ffi/src/goals.rs rust/ffi/src/lib.rs rust/ffi/src/chat.rs
git commit -m "feat: expose typed on-device goal lifecycle"
```

---

### Task 9: Refactor the query turn boundary for goal reuse

**Files:**
- Modify: `rust/ffi/src/chat.rs`
- Test: `rust/ffi/src/chat.rs`

- [ ] **Step 1: Write failing turn-boundary tests**

Add:

```rust
#[tokio::test]
async fn loop_inputs_use_canonical_session_id_and_shared_tracker() {
    let (session, _) = cancellation_test_session(None).await;
    let tracker = Arc::new(CostTracker::default());
    let (_, _, context) = session
        .build_loop_inputs(tracker.clone(), None)
        .unwrap();
    assert_eq!(context.session_id, session.session_id);
    assert!(Arc::ptr_eq(&context.cost_tracker, &tracker));
}

#[test]
fn goal_tools_add_only_goal_complete_to_the_file_profile() {
    let root = std::env::current_dir().unwrap();
    let storage = test_goal_storage("goal-tools");
    let tools = sandbox_goal_tools(
        &root,
        Arc::new(PermissionState::new(ChatPermissionMode::Default)),
        None,
        storage,
    );
    let names: Vec<&str> = tools.iter().map(|tool| tool.name()).collect();
    assert_eq!(names.len(), FILE_TOOLS.len() + 1);
    assert!(names.contains(&"GoalComplete"));
    assert!(names
        .iter()
        .all(|name| FILE_TOOLS.contains(name) || *name == "GoalComplete"));
}

#[test]
fn goal_journal_records_only_durable_query_messages() {
    let mut journal = Vec::new();
    record_goal_journal_event(
        &mut journal,
        QueryEvent::DurableMessage {
            message: Message::assistant("working"),
        },
    );
    assert_eq!(journal.len(), 1);
    assert_eq!(journal[0].get_all_text(), "working");
}

#[test]
fn goal_journal_is_independent_of_compacted_working_history() {
    let mut journal = vec![Message::assistant("durable output")];
    let mut working = vec![Message::user("old context")];
    working = vec![Message::user("compacted summary")];
    assert_eq!(journal.remove(0).get_all_text(), "durable output");
    assert_eq!(working[0].get_all_text(), "compacted summary");
}
```

Add a deterministic executor-seam regression that drives two synthetic goal
turns without a provider or network and proves both turns receive the same
cancellation token, canonical session ID, and `Arc<CostTracker>`.

- [ ] **Step 2: Confirm red**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi \
  chat::tests::loop_inputs_use_canonical_session_id_and_shared_tracker
cargo test -p coven-pocket-ffi \
  chat::tests::goal_tools_add_only_goal_complete_to_the_file_profile
cargo test -p coven-pocket-ffi \
  chat::tests::goal_journal_records_only_durable_query_messages
cargo test -p coven-pocket-ffi \
  chat::tests::goal_journal_is_independent_of_compacted_working_history
```

Expected: compilation fails on the new signatures/helpers.

- [ ] **Step 3: Share the tracker and canonical session ID**

Change:

```rust
fn build_loop_inputs(
    &self,
    cost_tracker: Arc<CostTracker>,
    goal: Option<&claurst_core::Goal>,
) -> Result<(AnthropicClient, QueryConfig, ToolContext), PocketError>
```

Append `goal_system_prompt_addendum(goal)` only when `goal` is supplied. Set:

```rust
cost_tracker: cost_tracker.clone(),
session_id: self.session_id.clone(),
```

Pass the same tracker to `run_query_loop`. Ordinary `send` creates one tracker
for that one turn, preserving ordinary-chat behavior.

Extract the query invocation behind a private generic async turn executor. The
production adapter calls `run_query_loop`; Rust tests pass a deterministic
closure that returns scripted `QueryOutcome` values and durable events. Keep
the seam concrete and generic rather than storing type-erased test behavior on
the UniFFI object. This seam must exist before autonomous-run tests so
multi-turn, completion, failure, and pause races never depend on provider
credentials or the `TEST_IMMEDIATE_END_TURN_MODEL` shortcut.

- [ ] **Step 4: Add the checked goal-only tool registry**

Build ordinary file tools first, then append:

```rust
Box::new(CheckedGoalCompleteTool::new(
    claurst_tools::GoalCompleteTool::at_path(goal_storage.path()?),
    goal_storage,
))
```

`CheckedGoalCompleteTool::execute` validates the goal SQLite family before and
after delegating. A validation failure becomes `ToolResult::error` with the
real storage message. It has `PermissionLevel::None` and does not pass through
the write approval gate.

- [ ] **Step 5: Add a compaction-safe goal message journal**

Extend `spawn_event_forwarder` with a `collect_durable_messages` flag and return
the collected vector:

```rust
fn record_goal_journal_event(
    journal: &mut Vec<Message>,
    event: QueryEvent,
) -> Option<QueryEvent> {
    match event {
        QueryEvent::DurableMessage { message } => {
            journal.push(message);
            None
        }
        other => Some(other),
    }
}
```

The forwarder applies this function before its existing UI event match. In
ordinary chat it consumes but does not collect `DurableMessage`; in a goal run
it returns the durable journal after flushing all events.

The goal runner keeps two histories:

- `self.messages` remains the full durable/UI transcript; and
- a local `working_messages` vector is passed back through autonomous turns and
  may be compacted or rewritten by coven-code.

Each continuation gets a unique UUID and is appended only to
`working_messages`. After the query returns, remove that UUID if compaction
retained it, append the event journal to `self.messages`, and strictly persist
that durable vector. Never derive durable output from a position or prefix in
`working_messages`.

- [ ] **Step 6: Run focused and ordinary-chat regressions**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi chat::tests::loop_inputs_use_canonical_session_id_and_shared_tracker
cargo test -p coven-pocket-ffi chat::tests::goal_tools_add_only_goal_complete_to_the_file_profile
cargo test -p coven-pocket-ffi chat::tests::goal_journal_records_only_durable_query_messages
cargo test -p coven-pocket-ffi chat::tests::goal_journal_is_independent_of_compacted_working_history
cargo test -p coven-pocket-ffi chat::tests::sandbox_profile_allows_only_file_tools -- --exact
```

Expected: all pass; ordinary registry still excludes `GoalComplete`.

- [ ] **Step 7: Commit the reusable turn boundary**

Run:

```bash
git add rust/ffi/src/chat.rs
git commit -m "refactor: prepare chat turns for goal continuation"
```

---

### Task 10: Implement the autonomous Rust goal runner

**Files:**
- Modify: `rust/ffi/src/chat.rs`
- Modify: `rust/ffi/src/goals.rs`
- Test: `rust/ffi/src/chat.rs`

- [ ] **Step 1: Add failing autonomous-run tests**

Use the deterministic query-turn executor introduced in Task 9. Script
terminal outcomes and durable-message events directly; these tests must not
depend on provider credentials, network access, sleeps, or repeated
`max_turns = 0` calls:

```rust
#[tokio::test]
async fn goal_run_reaches_the_engine_runaway_guard_without_persisting_continuations() {
    let storage = test_storage("goal-runaway");
    let (session, _) = immediate_goal_session(&storage).await;
    let progress = Arc::new(RecordingGoalDelegate::default());
    let result = session
        .start_goal(
            "finish the feature".to_string(),
            None,
            Arc::new(NoopChatDelegate),
            progress.clone(),
        )
        .await
        .unwrap();
    assert_eq!(
        progress.snapshots()[0].status,
        PocketGoalStatus::Active,
        "the initial snapshot must publish before the first query"
    );
    assert_eq!(result.reason, GoalRunStopReason::RunawayGuard);
    let snapshot = result.snapshot.unwrap();
    assert_eq!(snapshot.turns_used, claurst_core::MAX_GOAL_TURNS);
    let transcript = session.transcript().await;
    assert_eq!(
        transcript
            .iter()
            .filter(|message| message.role == "user")
            .count(),
        1
    );
    assert!(transcript[0].text.starts_with("/goal "));
}

#[tokio::test]
async fn pause_wins_the_turn_completion_race() {
    let storage = test_storage("goal-pause-race");
    let (session, _) = paused_goal_session(&storage).await;
    let run = {
        let session = session.clone();
        tokio::spawn(async move {
            session
                .start_goal(
                    "finish".to_string(),
                    None,
                    Arc::new(NoopChatDelegate),
                    Arc::new(RecordingGoalDelegate::default()),
                )
                .await
        })
    };
    wait_until_busy(&session).await;
    let paused = session.pause_goal().await.unwrap();
    assert_eq!(paused.status, PocketGoalStatus::Paused);
    let result = run.await.unwrap().unwrap();
    assert_eq!(result.reason, GoalRunStopReason::Paused);
}

#[tokio::test]
async fn goal_runtime_failure_persists_paused_state() {
    let storage = test_storage("goal-runtime-error");
    let session = failing_goal_session(&storage).await;
    let progress = Arc::new(RecordingGoalDelegate::default());
    let result = session
        .start_goal(
            "finish".to_string(),
            None,
            Arc::new(NoopChatDelegate),
            progress.clone(),
        )
        .await
        .unwrap();
    assert_eq!(result.reason, GoalRunStopReason::RuntimeError);
    assert!(result.error_message.is_some());
    assert_eq!(
        result.snapshot.as_ref().unwrap().status,
        PocketGoalStatus::Paused
    );
    assert_eq!(progress.snapshots()[0].status, PocketGoalStatus::Active);
}

#[tokio::test]
async fn clear_racing_a_turn_stops_without_recreating_or_pausing_the_goal() {
    let storage = test_storage("goal-clear-race");
    let (session, _) = paused_goal_session(&storage).await;
    let run = {
        let session = session.clone();
        tokio::spawn(async move {
            session
                .start_goal(
                    "finish".to_string(),
                    None,
                    Arc::new(NoopChatDelegate),
                    Arc::new(RecordingGoalDelegate::default()),
                )
                .await
        })
    };
    wait_until_busy(&session).await;
    session.clear_goal().await.unwrap();
    let result = run.await.unwrap().unwrap();
    assert_eq!(result.reason, GoalRunStopReason::Cleared);
    assert!(session.goal_status().await.unwrap().is_none());
}
```

Test helpers may use a test-only pause point like the existing persistence
pause hooks; they must not add sleeps as synchronization.

- [ ] **Step 2: Confirm the runner tests fail**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi \
  chat::tests::goal_run_reaches_the_engine_runaway_guard_without_persisting_continuations
cargo test -p coven-pocket-ffi \
  chat::tests::pause_wins_the_turn_completion_race
cargo test -p coven-pocket-ffi \
  chat::tests::goal_runtime_failure_persists_paused_state
cargo test -p coven-pocket-ffi \
  chat::tests::clear_racing_a_turn_stops_without_recreating_or_pausing_the_goal
```

Expected: compilation fails because `start_goal` is absent.

- [ ] **Step 3: Add the exported start/resume API**

Add:

```rust
pub async fn start_goal(
    &self,
    objective: String,
    token_budget: Option<u64>,
    chat_delegate: Arc<dyn ChatDelegate>,
    goal_delegate: Arc<dyn GoalProgressDelegate>,
) -> Result<GoalRunResult, PocketError>;

pub async fn resume_goal(
    &self,
    chat_delegate: Arc<dyn ChatDelegate>,
    goal_delegate: Arc<dyn GoalProgressDelegate>,
) -> Result<GoalRunResult, PocketError>;
```

Start creates the goal, pushes one canonical user message:

```rust
let initiating_prompt = match token_budget {
    Some(budget) => format!("/goal --tokens {budget} {objective}"),
    None => format!("/goal {objective}"),
};
```

Resume loads and validates the existing goal without adding a user-authored
message, then durably calls `goals::resume` before dispatch. Start and resume
both call `goal_delegate.on_goal_snapshot(active_snapshot)` before building the
first query request, so in-app state, ActivityKit, and the background
coordinator know execution is active throughout the first turn.

- [ ] **Step 4: Drive one cancellation and cost scope**

Factor the current busy/cancellation publication into a guard used by ordinary
and goal runs. The goal runner:

```rust
let cost_tracker = Arc::new(CostTracker::default());
let starting_tokens = goal.tokens_used;
let mut next_prompt = if is_resume {
    Some(claurst_core::goal_continuation_message(&goal))
} else {
    None
};

loop {
    let turn_started = std::time::Instant::now();
    let turn = self
        .run_goal_turn(
            &mut working_messages,
            next_prompt.take(),
            &goal,
            cost_tracker.clone(),
            chat_delegate.clone(),
            goal_storage.clone(),
            cancel_token.clone(),
        )
        .await?;
    durable_messages.extend(turn.durable_messages);
    self.persist_goal_messages(&durable_messages).await?;
    let outcome = turn.outcome;
    if matches!(outcome, QueryOutcome::Cancelled) {
        return self.pause_cancelled_goal(goal_storage.clone()).await;
    }
    let total_tokens = starting_tokens
        .saturating_add(cost_tracker.total_tokens());
    let decision = goals::continue_after_turn(
        goal_storage.clone(),
        self.session_id.clone(),
        total_tokens,
        turn_started.elapsed().as_secs(),
    )
    .await?;
    match decision {
        GoalContinuation::Continue { message } => {
            let snapshot = goals::required_snapshot(
                goal_storage.clone(),
                self.session_id.clone(),
            )
            .await?;
            goal_delegate.on_goal_snapshot(snapshot);
            next_prompt = Some(message);
        }
        GoalContinuation::Stop { reason } => {
            let snapshot = goals::required_snapshot(
                goal_storage.clone(),
                self.session_id.clone(),
            )
            .await?;
            return Ok(goals::run_result(reason, Some(snapshot)));
        }
        GoalContinuation::NoGoal => {
            return Ok(GoalRunResult {
                reason: GoalRunStopReason::Cleared,
                snapshot: None,
                error_message: None,
            });
        }
    }
}
```

`durable_messages` starts as the locked canonical session transcript.
`working_messages` starts as its clone and is retained separately across loop
iterations inside `run_goal_turn`. `GoalTurnOutput` contains the query outcome
and the durable event journal; it never exposes a positional message suffix.

- [ ] **Step 5: Make goal transcript persistence strict**

Keep ordinary `persist_new` best-effort. Add:

```rust
async fn persist_goal_messages(
    &self,
    messages: &[Message],
) -> Result<(), PocketError> {
    let persistence = self.persistence.as_ref().ok_or_else(|| {
        PocketError::Engine {
            message: "goals require a persisted on-device session".to_string(),
        }
    })?;
    persistence.persist_new(messages).await
}
```

Persist the initiating message before the first request and all model/tool
outputs before checking continuation. Any persistence failure pauses the goal
and returns the combined persistence/pause error.
Internal autonomous turns forward text, thinking, tool, status, and permission
events through `ChatDelegate`, but they do not emit `on_done` or `on_error`.
The async goal method has one terminal return or thrown error for the complete
run, preventing false per-turn completion UI.

- [ ] **Step 6: Handle every terminal outcome**

Map:

- engine completion -> `Complete`;
- durable paused state -> `Paused`;
- budget state -> `BudgetLimited`;
- runaway stop -> `RunawayGuard`;
- cleared record -> `Cleared`;
- query cancellation after explicit pause -> return `Paused`;
- query cancellation with an active record -> persist `Paused`,
  return `Cancelled`;
- query/provider error -> persist `Paused`, return
  `RuntimeError` with the original message;
- transcript or goal-store error -> best-effort persist `Paused`, return
  `StorageError` with the original and pause errors combined;
- clear racing any outcome -> return `Cleared` with no snapshot.

Never schedule another turn after reloading a non-active snapshot.
Every post-start terminal path returns `GoalRunResult`; before returning, it
reloads the durable terminal snapshot when storage is readable. It does not
send terminal snapshots through `GoalProgressDelegate`; Swift applies the
snapshot and typed reason together from the reserved terminal result sequence.
The last known snapshot is retained only when the storage failure prevents a
reload. This lets Swift end busy and ActivityKit state exactly once even when
persistence is unavailable.

- [ ] **Step 7: Run runner and ordinary cancellation tests**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi chat::tests::goal_run_reaches_the_engine_runaway_guard_without_persisting_continuations
cargo test -p coven-pocket-ffi chat::tests::pause_wins_the_turn_completion_race
cargo test -p coven-pocket-ffi chat::tests::goal_runtime_failure_persists_paused_state
cargo test -p coven-pocket-ffi chat::tests::clear_racing_a_turn_stops_without_recreating_or_pausing_the_goal
cargo test -p coven-pocket-ffi chat::tests::stop_while_waiting_for_messages_cancels_before_loop_setup -- --exact
cargo test -p coven-pocket-ffi chat::tests::stop_while_persisting_cancels_before_loop_setup -- --exact
```

Expected: all pass.

- [ ] **Step 8: Commit the autonomous runner**

Run:

```bash
git add rust/ffi/src/chat.rs rust/ffi/src/goals.rs
git commit -m "feat: run durable on-device goals"
```

---

### Task 11: Integrate goals with session deletion, recovery, and forks

**Files:**
- Modify: `rust/ffi/src/sessions.rs`
- Test: `rust/ffi/src/sessions.rs`

- [ ] **Step 1: Write failing lifecycle regressions**

Add:

```rust
#[tokio::test]
async fn deleting_a_session_clears_its_goal_only() {
    let storage = test_storage("delete-goal");
    let (target_id, _) = create_persisted_test_session(&storage).await;
    let (other_id, _) = create_persisted_test_session(&storage).await;
    let goals = GoalStorage::open(&storage.to_string_lossy()).unwrap();
    goals
        .with_store(|store| {
            store.set_goal(&target_id, "target", None)?;
            store.set_goal(&other_id, "other", None)?;
            Ok(())
        })
        .unwrap();

    delete_session(&storage.to_string_lossy(), &target_id)
        .await
        .unwrap();
    goals
        .with_store(|store| {
            assert!(store.try_get_goal(&target_id)?.is_none());
            assert!(store.try_get_goal(&other_id)?.is_some());
            Ok(())
        })
        .unwrap();
}

#[tokio::test]
async fn pending_deletion_recovery_retries_goal_cleanup() {
    let storage = test_storage("recover-goal-delete");
    let (session_id, _) = create_persisted_test_session(&storage).await;
    let checked = CheckedStorage::from_root(&storage).unwrap();
    let mut lifecycle = SESSION_LIFECYCLE_LOCK.write().await;
    begin_session_deletion_and_tombstone(
        &checked,
        &mut lifecycle,
        &session_id,
    )
    .unwrap();
    drop(lifecycle);

    list_sessions(&storage.to_string_lossy()).await.unwrap();
    GoalStorage::open(&storage.to_string_lossy())
        .unwrap()
        .with_store(|store| {
            assert!(store.try_get_goal(&session_id)?.is_none());
            Ok(())
        })
        .unwrap();
}

#[tokio::test]
async fn fork_does_not_inherit_the_source_goal() {
    let storage = test_storage("fork-goal");
    let (source_id, _) = create_persisted_test_session(&storage).await;
    let goals = GoalStorage::open(&storage.to_string_lossy()).unwrap();
    goals
        .with_store(|store| {
            store.set_goal(&source_id, "source only", None)?;
            Ok(())
        })
        .unwrap();
    let fork_id = fork_session(&storage.to_string_lossy(), &source_id)
        .await
        .unwrap();
    goals
        .with_store(|store| {
            assert!(store.try_get_goal(&source_id)?.is_some());
            assert!(store.try_get_goal(&fork_id)?.is_none());
            Ok(())
        })
        .unwrap();
}
```

- [ ] **Step 2: Confirm the lifecycle tests fail**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi \
  sessions::tests::deleting_a_session_clears_its_goal_only
cargo test -p coven-pocket-ffi \
  sessions::tests::pending_deletion_recovery_retries_goal_cleanup
cargo test -p coven-pocket-ffi \
  sessions::tests::fork_does_not_inherit_the_source_goal
```

Expected: delete/recovery tests fail because cleanup does not clear goals.

- [ ] **Step 3: Make cleanup clear goals under its durable marker**

Extend the deletion/recovery preflight to validate the `goals.sqlite` family
before any index or session artifact is mutated. In
`cleanup_session_artifacts`, after that preflight succeeds and before index
deletion:

```rust
let goal_storage = GoalStorage {
    storage: storage.clone(),
};
if let Err(error) =
    goal_storage.with_store(|store| store.clear_goal(session_id))
{
    return Err(cleanup_error(
        storage,
        session_id,
        marker,
        vec![format!("cannot clear session goal: {error}")],
    ));
}
```

Because the pending deletion/fork marker already exists, a later recovery
retries this idempotent clear. Add goal absence to
`verify_session_artifacts_absent`.

- [ ] **Step 4: Run lifecycle and serialization regressions**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi sessions::tests::deleting_a_session_clears_its_goal_only
cargo test -p coven-pocket-ffi sessions::tests::pending_deletion_recovery_retries_goal_cleanup
cargo test -p coven-pocket-ffi sessions::tests::fork_does_not_inherit_the_source_goal
cargo test -p coven-pocket-ffi sessions::tests::resume_and_delete_serialize_through_the_lifecycle_lock -- --exact
cargo test -p coven-pocket-ffi sessions::tests::failed_fork_publication_is_quarantined_until_restart_recovery -- --exact
```

Expected: all pass.

- [ ] **Step 5: Commit session lifecycle integration**

Run:

```bash
git add rust/ffi/src/sessions.rs
git commit -m "fix: bind goals to session lifecycle cleanup"
```

---

### Task 12: Regenerate and validate the UniFFI boundary

**Files:**
- Modify generated: `app/Sources/Generated/coven_pocket_ffi.swift`
- Modify generated framework under ignored `build/`

- [ ] **Step 1: Run Rust formatting and focused tests**

Run:

```bash
cd rust
cargo fmt --all
cargo test -p coven-pocket-ffi goals::
cargo test -p coven-pocket-ffi chat::tests::goal_run_reaches_the_engine_runaway_guard_without_persisting_continuations
cargo test -p coven-pocket-ffi sessions::tests::deleting_a_session_clears_its_goal_only
cargo check -p coven-pocket-ffi
```

Expected: all pass.

- [ ] **Step 2: Regenerate framework and Swift**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
./scripts/build-xcframework.sh
```

Expected: all device/simulator slices and generated Swift bindings succeed.

- [ ] **Step 3: Inspect the generated API**

Run:

```bash
rg -n 'PocketGoalStatus|GoalSnapshot|GoalRunResult|GoalProgressDelegate|startGoal|resumeGoal|goalStatus|pauseGoal|clearGoal|reconcileGoals' \
  app/Sources/Generated/coven_pocket_ffi.swift
git diff --check
```

Expected: every planned type/method appears once; no hand edits or whitespace
errors exist.

- [ ] **Step 4: Commit generated bindings**

Run:

```bash
git add app/Sources/Generated/coven_pocket_ffi.swift
git commit -m "build: generate on-device goal bindings"
```

---

### Task 13: Parse `/goal` commands exactly in Swift

**Files:**
- Create: `app/Sources/Support/Goals/GoalCommandParser.swift`
- Create: `app/Tests/GoalCommandParserTests.swift`

- [ ] **Step 1: Write parser tests**

Define these cases:

```swift
final class GoalCommandParserTests: XCTestCase {
    func testNonGoalTextPassesThrough() {
        XCTAssertEqual(GoalCommandParser.parse("hello"), .notGoal)
        XCTAssertEqual(GoalCommandParser.parse("/goalie"), .notGoal)
    }

    func testStartCommandsPreserveObjectiveAndBudget() {
        XCTAssertEqual(
            GoalCommandParser.parse(" /goal ship the feature "),
            .command(.start(objective: "ship the feature", tokenBudget: nil))
        )
        XCTAssertEqual(
            GoalCommandParser.parse("/goal --tokens 12000 ship it"),
            .command(.start(objective: "ship it", tokenBudget: 12_000))
        )
    }

    func testExactActionsHaveNoArguments() {
        XCTAssertEqual(GoalCommandParser.parse("/goal status"), .command(.status))
        XCTAssertEqual(GoalCommandParser.parse("/goal pause"), .command(.pause))
        XCTAssertEqual(GoalCommandParser.parse("/goal resume"), .command(.resume))
        XCTAssertEqual(GoalCommandParser.parse("/goal clear"), .command(.clear))
        XCTAssertEqual(
            GoalCommandParser.parse("/goal status page rollout"),
            .command(.start(
                objective: "status page rollout",
                tokenBudget: nil
            ))
        )
    }

    func testMalformedBudgetAndMissingObjectiveAreLocalErrors() {
        for input in [
            "/goal",
            "/goal --tokens",
            "/goal --tokens 0 ship",
            "/goal --tokens nope ship",
            "/goal --tokens 9223372036854775808 ship",
            "/goal --tokens 18446744073709551616 ship",
            "/goal --unknown ship"
        ] {
            guard case .error = GoalCommandParser.parse(input) else {
                return XCTFail("expected local error for \(input)")
            }
        }
    }
}
```

- [ ] **Step 2: Confirm parser tests fail**

Run:

```bash
xcodegen generate
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalCommandParserTests
```

Expected: compilation fails because parser types do not exist.

- [ ] **Step 3: Implement the pure parser**

Define:

```swift
enum GoalCommand: Equatable {
    case start(objective: String, tokenBudget: UInt64?)
    case status
    case pause
    case resume
    case clear
}

enum GoalCommandParseResult: Equatable {
    case notGoal
    case command(GoalCommand)
    case error(String)
}

enum GoalCommandParser {
    static let usage =
        "Use /goal <objective>, /goal --tokens <budget> <objective>, "
        + "/goal status, /goal pause, /goal resume, or /goal clear."

    static func parse(_ input: String) -> GoalCommandParseResult
}
```

Recognize `/goal` only when the trimmed input equals `/goal` or starts with
`/goal` followed by whitespace. Exact one-word action remainders are actions.
For `--tokens`, split at the first two whitespace runs, parse `UInt64`, reject
zero or values above `UInt64(Int64.max)`, and preserve the remaining trimmed
objective. Reject any other leading `--` token. This gives immediate local
feedback for budgets SQLite cannot represent; the engine independently
validates the same boundary for all callers.

- [ ] **Step 4: Run and commit parser tests**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalCommandParserTests
git add app/Sources/Support/Goals/GoalCommandParser.swift \
  app/Tests/GoalCommandParserTests.swift
git commit -m "feat: parse on-device goal commands"
```

Expected: parser tests pass and the commit contains only parser code/tests.

---

### Task 14: Bridge goal progress and model lifecycle

**Files:**
- Create: `app/Sources/Support/Goals/GoalProgressBridge.swift`
- Modify: `app/Sources/Support/ChatModel.swift`
- Create: `app/Tests/GoalChatModelTests.swift`

- [ ] **Step 1: Write model lifecycle tests with a generated-session stub**

Create a `GoalStubChatSession: ChatSession` overriding `startGoal`,
`resumeGoal`, `goalStatus`, `pauseGoal`, and `clearGoal`. Test:

```swift
@MainActor
func testGoalProgressBridgePublishesOnlyCurrentGeneration() async {
    let stub = GoalStubChatSession()
    let model = goalModel(session: stub)
    await model.startGoal(
        objective: "ship",
        tokenBudget: 1_000,
        settings: codexSettings,
        selectedFamiliar: nil
    )
    stub.publish(snapshot(status: .active, turns: 1))
    await Task.yield()
    XCTAssertEqual(model.goal?.turnsUsed, 1)

    model.reset()
    stub.publish(snapshot(status: .active, turns: 2))
    await Task.yield()
    XCTAssertNil(model.goal)
}

@MainActor
func testPauseWritesGoalStateAndStopsBusyPresentation() async {
    let stub = SuspendedGoalChatSession()
    let model = goalModel(session: stub)
    let run = Task {
        await model.startGoal(
            objective: "ship",
            tokenBudget: nil,
            settings: codexSettings,
            selectedFamiliar: nil
        )
    }
    await fulfillment(of: [stub.startRequested], timeout: 1)
    XCTAssertTrue(model.isBusy)
    await model.pauseGoal()
    XCTAssertEqual(stub.pauseCallCount, 1)
    stub.finish(with: runResult(.paused, snapshot(status: .paused)))
    await run.value
    XCTAssertFalse(model.isBusy)
    XCTAssertEqual(model.goal?.status, .paused)
}

@MainActor
func testResumeRejectsBudgetLimitedAndRunawaySnapshotsLocally() async {
    let stub = GoalStubChatSession()
    let model = goalModel(session: stub)
    model.receiveGoalSnapshot(snapshot(status: .budgetLimited))
    await model.resumeGoal()
    XCTAssertEqual(stub.resumeCallCount, 0)
    XCTAssertNotNil(model.goalError)
}

@MainActor
func testOlderGoalCallbackCannotOverwriteTerminalState() {
    let model = ChatModel()
    model.receiveGoalSnapshot(
        snapshot(status: .paused),
        generation: nil,
        callbackSequence: 2
    )
    model.receiveGoalSnapshot(
        snapshot(status: .active),
        generation: nil,
        callbackSequence: 1
    )
    XCTAssertEqual(model.goal?.status, .paused)
}
```

Also cover clear, status refresh after session resume, a new session clearing the
old card, runtime error retaining the last snapshot, Companion commands not
reaching this model, and account/backend/model/Familiar/reset requests being
blocked or routed through durable pause while a goal owns the session.

- [ ] **Step 2: Confirm the model tests fail**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalChatModelTests
```

Expected: compilation fails on missing model APIs.

- [ ] **Step 3: Implement the Rust-thread bridge**

Create:

```swift
final class GoalProgressBridge: GoalProgressDelegate, @unchecked Sendable {
    weak var model: ChatModel?
    private let generation: UInt64
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    init(model: ChatModel, generation: UInt64) {
        self.model = model
        self.generation = generation
    }

    func onGoalSnapshot(snapshot: GoalSnapshot) {
        let callbackSequence = reserveSequence()
        Task {
            @MainActor [weak model, generation, callbackSequence] in
            model?.receiveGoalSnapshot(
                snapshot,
                generation: generation,
                callbackSequence: callbackSequence
            )
        }
    }

    func reserveSequence() -> UInt64 {
        lock.withLock {
            sequence &+= 1
            return sequence
        }
    }
}
```

Use a dedicated `goalRunGeneration`, incremented for every start, resume,
clear, reset, or session replacement rather than reusing transcript generation.
The model resets the greatest accepted callback sequence when that generation
changes and drops lower values within a run. After the async FFI call returns,
reserve one more sequence on the same bridge and apply the terminal
`GoalRunResult` with it; any earlier callback task that reaches `@MainActor`
later is stale.

- [ ] **Step 4: Add model state and start/resume operations**

Add:

```swift
@Published private(set) var goal: GoalSnapshot?
@Published private(set) var goalError: String?
@Published private(set) var goalStopReason: GoalRunStopReason?
@Published private(set) var goalsReady = false

var isGoalRunning: Bool {
    goal?.status == .active && isBusy
}
```

Use the existing `claimOperation`, `activeSession`, active Familiar, session
replacement, and transcript generation rules. Start appends one user row with
the canonical command text and invokes `startGoal`. Resume invokes
`resumeGoal`. Both use `GenerationChatBridge` plus `GoalProgressBridge`, apply
the returned snapshot and typed stop reason at the bridge's reserved terminal
sequence. `errorMessage` becomes `goalError`; runtime/storage results do not
throw away the last durable snapshot.

- [ ] **Step 5: Add status, pause, clear, and preparation**

Implement:

```swift
func prepareGoals() async
func refreshGoalStatus() async
func pauseGoal() async
func resumeGoal() async
func clearGoal() async
```

`prepareGoals` calls `engine.reconcileGoals(storageDir:)` exactly once per
model, records any error in `goalError`, and always sets `goalsReady = true` so
ordinary chat remains usable. It does not invent a snapshot for an uninstalled
session.

Do not let synchronous reset, account, backend, model, Familiar, or clear-chat
paths discard an active goal owner. Disable those mutations while a goal is
active, or route their async entry point through `pauseGoal()` before `stop()`
and replacement. Session replacement after a durable pause may call `stop()`
as a cancellation backstop. Clear goal UI state only after advancing transcript
and goal generations.

- [ ] **Step 6: Run model and existing chat-state tests**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalChatModelTests \
  -only-testing:CovenPocketTests/ChatSurfaceTests
```

Expected: both suites pass.

- [ ] **Step 7: Commit bridge and model lifecycle**

Run:

```bash
git add app/Sources/Support/Goals/GoalProgressBridge.swift \
  app/Sources/Support/ChatModel.swift app/Tests/GoalChatModelTests.swift
git commit -m "feat: coordinate goal state in chat"
```

---

### Task 15: Pause goals at bounded iOS background expiration

**Files:**
- Create: `app/Sources/Support/Goals/GoalExecutionCoordinator.swift`
- Create: `app/Tests/GoalExecutionCoordinatorTests.swift`

- [ ] **Step 1: Write background ownership tests**

Use a fake adapter with a captured expiration closure:

```swift
@MainActor
func testBackgroundStartsOneClaimAndForegroundEndsItOnce() async {
    let tasks = FakeBackgroundTaskManager()
    var pauses = 0
    let coordinator = GoalExecutionCoordinator(
        backgroundTasks: tasks,
        isGoalRunning: { true },
        pause: { pauses += 1 }
    )
    coordinator.enterBackground()
    coordinator.enterBackground()
    XCTAssertEqual(tasks.beginCount, 1)
    coordinator.enterForeground()
    coordinator.enterForeground()
    XCTAssertEqual(tasks.endCount, 1)
    XCTAssertEqual(pauses, 0)
}

@MainActor
func testExpirationPausesThenEndsClaim() async {
    let tasks = FakeBackgroundTaskManager()
    let pauseStarted = expectation(description: "pause started")
    let pauseFinished = expectation(description: "pause finished")
    let gate = AsyncTestGate()
    let coordinator = GoalExecutionCoordinator(
        backgroundTasks: tasks,
        isGoalRunning: { true },
        pause: {
            pauseStarted.fulfill()
            await gate.wait()
            pauseFinished.fulfill()
        }
    )
    coordinator.enterBackground()
    tasks.expire()
    await fulfillment(of: [pauseStarted], timeout: 1)
    XCTAssertEqual(tasks.endCount, 0)
    await gate.open()
    await fulfillment(of: [pauseFinished], timeout: 1)
    await Task.yield()
    XCTAssertEqual(tasks.endCount, 1)
}

@MainActor
func testDeniedClaimImmediatelyPauses() async {
    let tasks = FakeBackgroundTaskManager()
    tasks.shouldDeny = true
    let paused = expectation(description: "paused")
    let coordinator = GoalExecutionCoordinator(
        backgroundTasks: tasks,
        isGoalRunning: { true },
        pause: { paused.fulfill() }
    )
    coordinator.enterBackground()
    await fulfillment(of: [paused], timeout: 1)
    XCTAssertEqual(tasks.beginCount, 1)
}

@MainActor
func testGoalBecomingActiveAfterBackgroundStartsAClaim() {
    let tasks = FakeBackgroundTaskManager()
    var running = false
    let coordinator = GoalExecutionCoordinator(
        backgroundTasks: tasks,
        isGoalRunning: { running },
        pause: {}
    )
    coordinator.enterBackground()
    XCTAssertEqual(tasks.beginCount, 0)
    running = true
    coordinator.goalExecutionStarted()
    XCTAssertEqual(tasks.beginCount, 1)
}
```

`AsyncTestGate` is a small test actor backed by one checked continuation; it
lets the test prove ordering without sleeps.

- [ ] **Step 2: Confirm coordinator tests fail**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalExecutionCoordinatorTests
```

Expected: missing types fail compilation.

- [ ] **Step 3: Implement an injectable UIKit adapter**

Define an app-owned token:

```swift
struct GoalBackgroundTaskToken: Hashable {
    let id: UUID
}

@MainActor
protocol GoalBackgroundTaskManaging {
    func begin(
        name: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> GoalBackgroundTaskToken?
    func end(_ token: GoalBackgroundTaskToken)
}
```

`UIApplicationGoalBackgroundTaskManager` keeps a dictionary from app tokens to
`UIBackgroundTaskIdentifier`, returns `nil` for `.invalid`, and removes an ID
before ending it so expiration/foreground races are idempotent.

- [ ] **Step 4: Implement coordinator state transitions**

`GoalExecutionCoordinator` stores at most one token. `enterBackground` starts a
claim only when `isGoalRunning()` is true. Expiration marks the claim as
expiring, launches one main-actor task that awaits the durable Rust
pause-and-cancel operation, and ends the UIKit token in `defer` afterward.
While expiration is in progress, `enterForeground` cannot steal/end that token.
Normal foreground return and `goalExecutionEnded` clear/end a non-expiring
claim without pausing. The coordinator tracks whether the app is already in the
background. `goalExecutionStarted()` requests the claim when an initial active
callback arrives after `enterBackground`, closing the callback/scene race.

- [ ] **Step 5: Run and commit coordinator tests**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalExecutionCoordinatorTests
git add app/Sources/Support/Goals/GoalExecutionCoordinator.swift \
  app/Tests/GoalExecutionCoordinatorTests.swift
git commit -m "feat: bound goal execution to iOS background time"
```

Expected: tests pass and one focused commit is created.

---

### Task 16: Add privacy-safe ActivityKit state and lifecycle

**Files:**
- Create: `app/Sources/Support/Goals/GoalActivityAttributes.swift`
- Create: `app/Sources/Support/Goals/GoalActivityManager.swift`
- Create: `app/Tests/GoalActivityManagerTests.swift`

- [ ] **Step 1: Write activity mapping/lifecycle tests**

Use an injected `GoalActivityClient` closure bundle:

```swift
@MainActor
func testRunningSnapshotRequestsPrivacySafeActivity() async {
    let client = RecordingGoalActivityClient()
    let manager = GoalActivityManager(client: client.client)
    await manager.apply(
        snapshot(status: .active, objective: "private text"),
        revision: 1
    )
    XCTAssertEqual(client.requests.count, 1)
    XCTAssertFalse(client.requests[0].description.contains("private text"))
    XCTAssertEqual(client.requests[0].content.status, .running)
}

@MainActor
func testCompletedSnapshotEndsWithShortFinalDisplay() async {
    let client = RecordingGoalActivityClient()
    let manager = GoalActivityManager(client: client.client)
    await manager.apply(snapshot(status: .active), revision: 1)
    await manager.finish(
        runResult(.complete, snapshot(status: .complete)),
        revision: 2
    )
    XCTAssertEqual(client.ends.last?.dismissal, .shortFinal)
}

@MainActor
func testPauseEndsAndResumeRequestsAFreshActivity() async {
    let client = RecordingGoalActivityClient()
    let manager = GoalActivityManager(client: client.client)
    await manager.apply(snapshot(status: .active), revision: 1)
    await manager.finish(
        runResult(.paused, snapshot(status: .paused)),
        revision: 2
    )
    await manager.apply(snapshot(status: .active), revision: 3)
    XCTAssertEqual(client.requests.count, 2)
}

@MainActor
func testRuntimeErrorEndsActiveActivityAsNeedsAttention() async {
    let client = RecordingGoalActivityClient()
    let manager = GoalActivityManager(client: client.client)
    let active = snapshot(status: .active)
    await manager.apply(active, revision: 1)
    await manager.finish(
        GoalRunResult(
            reason: .runtimeError,
            snapshot: active,
            errorMessage: "provider failed"
        ),
        revision: 2
    )
    XCTAssertEqual(client.ends.last?.content?.status, .needsAttention)
    XCTAssertEqual(client.ends.last?.dismissal, .attention)
}

@MainActor
func testTerminalRevisionPreemptsSuspendedActiveUpdate() async {
    let client = RecordingGoalActivityClient()
    let gate = AsyncTestGate()
    client.suspendUpdates(on: gate)
    let manager = GoalActivityManager(client: client.client)
    let active = snapshot(status: .active)
    await manager.apply(active, revision: 1)

    let stale = Task {
        await manager.apply(
            snapshot(status: .active, turns: 2),
            revision: 2
        )
    }
    await client.updateStarted()
    await manager.finish(
        runResult(.runtimeError, snapshot(status: .paused)),
        revision: 3
    )
    await gate.open()
    _ = await stale.value

    XCTAssertNil(manager.activityIDForTesting)
    XCTAssertEqual(client.ends.last?.content?.status, .needsAttention)
}

@MainActor
func testLaunchCleanupEndsEveryStaleActivity() async {
    let client = RecordingGoalActivityClient(activeIDs: ["a", "b"])
    let manager = GoalActivityManager(client: client.client)
    await manager.endStaleActivities()
    XCTAssertEqual(Set(client.endedIDs), Set(["a", "b"]))
}
```

- [ ] **Step 2: Confirm activity tests fail**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalActivityManagerTests
```

Expected: missing types fail compilation.

- [ ] **Step 3: Define shared ActivityKit attributes**

Implement:

```swift
import ActivityKit
import Foundation

struct GoalActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            case running
            case paused
            case budgetLimited
            case complete
            case needsAttention
        }

        let status: Status
        let turnsUsed: UInt32
        let tokensUsed: UInt64
        let tokenBudget: UInt64?
        let elapsedSeconds: UInt64
        let updatedAt: Date
    }

    let goalID: String
    let sessionID: String
}
```

Do not add objective, transcript text, tool input, file paths, account data, or
Familiar data.

- [ ] **Step 4: Implement the ActivityKit client and manager**

Define a testable closure client:

```swift
struct GoalActivityClient {
    var request: (
        GoalActivityAttributes,
        GoalActivityAttributes.ContentState
    ) throws -> String
    var update: (
        String,
        GoalActivityAttributes.ContentState
    ) async -> Void
    var end: (
        String,
        GoalActivityAttributes.ContentState?,
        GoalActivityDismissal
    ) async -> Void
    var activeIDs: () -> [String]
}

enum GoalActivityDismissal: Equatable {
    case immediate
    case shortFinal
    case attention
}
```

The live adapter uses `Activity<GoalActivityAttributes>.request`,
`ActivityContent`, `update`, and `end`. The manager owns one activity ID,
requests only for `.active`, updates only on changed snapshot content, ends on
terminal state, and starts a fresh activity after resume. ActivityKit errors
are returned as a non-fatal availability message but never mutate
`GoalSnapshot`. Task 19 stores that return value on `ChatModel` for
`GoalCardView`.

Expose two serialized-operation primitives:

```swift
func apply(_ snapshot: GoalSnapshot, revision: UInt64) async -> String?
func finish(_ result: GoalRunResult, revision: UInt64) async -> String?
```

`finish` always ends the current activity. `complete` uses the short final
display; `paused`, `budgetLimited`, and `runawayGuard` use attention display;
`cleared` ends immediately; and `cancelled`, `runtimeError`, or `storageError`
use a `needsAttention` final state even when the last readable snapshot still
says active.
The manager accepts only revisions greater than its stored revision and records
the new revision before its first suspension point. After each ActivityKit
`await`, it rechecks the revision before retaining an activity ID or
availability message. A later `finish` therefore clears/ends the activity
without waiting for a stale active update, and that stale update cannot
reinstall state when it resumes.

- [ ] **Step 5: Run and commit ActivityKit manager tests**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalActivityManagerTests
git add app/Sources/Support/Goals/GoalActivityAttributes.swift \
  app/Sources/Support/Goals/GoalActivityManager.swift \
  app/Tests/GoalActivityManagerTests.swift
git commit -m "feat: publish privacy-safe goal activity state"
```

---

### Task 17: Add the WidgetKit Live Activity extension

**Files:**
- Create: `app/GoalWidgetExtension/CovenPocketGoalWidgetBundle.swift`
- Create: `app/GoalWidgetExtension/GoalLiveActivity.swift`
- Modify: `project.yml`

- [ ] **Step 1: Add the extension target configuration**

Add `NSSupportsLiveActivities: true` to the app Info properties. Add:

```yaml
  CovenPocketGoalWidget:
    type: app-extension
    platform: iOS
    info:
      path: build/CovenPocketGoalWidget-Info.plist
      properties:
        CFBundleDisplayName: Coven Pocket Goals
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    sources:
      - path: app/GoalWidgetExtension
      - path: app/Sources/Support/Goals/GoalActivityAttributes.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ai.opencoven.pocket.goal-widget
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
        APPLICATION_EXTENSION_API_ONLY: YES
```

Add to the app dependencies:

```yaml
      - target: CovenPocketGoalWidget
        embed: true
```

Add the extension target to the `CovenPocket` scheme build list.

- [ ] **Step 2: Write the widget bundle**

Create:

```swift
import SwiftUI
import WidgetKit

@main
struct CovenPocketGoalWidgetBundle: WidgetBundle {
    var body: some Widget {
        GoalLiveActivity()
    }
}
```

- [ ] **Step 3: Implement Lock Screen and minimal Dynamic Island views**

Create an `ActivityConfiguration(for: GoalActivityAttributes.self)` that:

- derives title solely from `ContentState.status`;
- shows turns and elapsed time;
- shows token progress only when a budget exists;
- uses `ProgressView(value:total:)` with clamped values;
- provides compact leading status symbol and compact trailing bounded progress;
- uses expanded leading/trailing/bottom regions for the same metrics;
- includes accessibility labels such as
  `"Goal running, 4 turns, 1200 of 5000 tokens"`; and
- never renders raw goal/session IDs.

Use helpers:

```swift
private func statusTitle(
    _ status: GoalActivityAttributes.ContentState.Status
) -> String

private func elapsed(_ seconds: UInt64) -> String

private func tokenFraction(
    used: UInt64,
    budget: UInt64?
) -> Double?
```

- [ ] **Step 4: Generate and build the extension**

Run:

```bash
xcodegen generate
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: both `CovenPocket.app` and
`CovenPocketGoalWidget.appex` compile and embed.

- [ ] **Step 5: Commit widget sources and generated-project definition**

Run:

```bash
git add project.yml app/GoalWidgetExtension
git commit -m "feat: add goal Live Activity extension"
```

Do not add `CovenPocket.xcodeproj`.

---

### Task 18: Render the goal card and route commands

**Files:**
- Create: `app/Sources/Views/Goals/GoalCardView.swift`
- Modify: `app/Sources/Views/ChatView.swift`
- Create: `app/Tests/GoalCardViewTests.swift`
- Modify: `app/Tests/GoalChatModelTests.swift`

- [ ] **Step 1: Write presentation and routing tests**

Test pure presentation:

```swift
func testGoalCardActionsMatchStatusAndTurnLimit() {
    XCTAssertEqual(
        GoalCardPresentation(snapshot: snapshot(status: .active)).actions,
        [.pause]
    )
    XCTAssertEqual(
        GoalCardPresentation(snapshot: snapshot(status: .paused)).actions,
        [.resume, .clear]
    )
    XCTAssertEqual(
        GoalCardPresentation(
            snapshot: snapshot(
                status: .paused,
                turns: snapshot(status: .paused).maxTurns
            )
        ).actions,
        [.startNew, .clear]
    )
    XCTAssertEqual(
        GoalCardPresentation(
            snapshot: snapshot(status: .budgetLimited)
        ).actions,
        [.startNew, .clear]
    )
    XCTAssertEqual(
        GoalCardPresentation(snapshot: snapshot(status: .complete)).actions,
        [.clear]
    )
}
```

In `GoalChatModelTests`, verify a parsed start invokes the goal session once,
an ordinary prompt invokes `send`, local parser errors append no user row, and
Companion routing leaves `/goal` untouched. Add a surface regression proving
account/backend/model/Familiar and clear-chat mutations cannot proceed while
an on-device goal is active.

- [ ] **Step 2: Confirm UI tests fail**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalCardViewTests \
  -only-testing:CovenPocketTests/GoalChatModelTests
```

Expected: presentation/routing APIs are missing.

- [ ] **Step 3: Build the typed card**

`GoalCardView` receives:

```swift
let snapshot: GoalSnapshot
let stopReason: GoalRunStopReason?
let error: String?
let activityMessage: String?
let onPause: () -> Void
let onResume: () -> Void
let onClear: () -> Void
let onStartNew: () -> Void
```

Show objective only inside the app. Show status, turns, elapsed, and token
budget progress. Use `.accessibilityElement(children: .combine)` for metrics
and explicit labels for icon-only controls.
When `stopReason` is `cancelled`, `runtimeError`, or `storageError`, present the
card as interrupted/needs-attention even if the last readable durable snapshot
still says active; never imply that execution continues when `isBusy` is false.
`onStartNew` stages `"/goal "` in the composer and focuses it without clearing
the existing goal; submitting the new objective performs the durable
replacement.

- [ ] **Step 4: Route exact goal commands only for Codex**

In `ChatView.send`, preserve Companion behavior. For Codex:

```swift
switch GoalCommandParser.parse(text) {
case .notGoal:
    await model.send(
        prompt: text,
        settings: settings,
        selectedFamiliar: familiarModel.selectedFamiliar
    )
case let .command(command):
    await model.performGoalCommand(
        command,
        settings: settings,
        selectedFamiliar: familiarModel.selectedFamiliar
    )
case let .error(message):
    model.presentGoalCommandError(message)
}
```

Insert the card between transcript and input divider. While a Codex goal runs,
the Stop button calls `await model.pauseGoal()` and uses accessibility label
`Pause goal`. Disable sending until `model.goalsReady`; ordinary chat remains
enabled after reconciliation failure.

- [ ] **Step 5: Run UI and chat regressions**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalCardViewTests \
  -only-testing:CovenPocketTests/GoalChatModelTests \
  -only-testing:CovenPocketTests/ChatSurfaceTests
```

Expected: all pass.

- [ ] **Step 6: Commit goal UI and routing**

Run:

```bash
git add app/Sources/Views/Goals/GoalCardView.swift \
  app/Sources/Views/ChatView.swift app/Tests/GoalCardViewTests.swift \
  app/Tests/GoalChatModelTests.swift
git commit -m "feat: add in-app goal controls"
```

---

### Task 19: Wire launch reconciliation, scene phase, and ActivityKit

**Files:**
- Modify: `app/Sources/Support/ChatModel.swift`
- Modify: `app/Sources/Views/RootView.swift`
- Modify: `app/Sources/CovenPocketApp.swift`
- Modify: `app/Tests/GoalChatModelTests.swift`
- Modify: `app/Tests/ChatSurfaceTests.swift`

- [ ] **Step 1: Write launch/scene integration tests**

Add tests that:

- the app-scoped `RootWindowState` owns one stable goal/background coordinator
  pair for the single supported scene;
- `prepareGoals()` is idempotent and ends all stale activities after engine
  reconciliation;
- background while a goal is active begins one claim;
- foreground ends it;
- a goal terminal snapshot ends the background claim and ActivityKit state;
- an active ActivityKit update suspended in the adapter cannot commit after a
  later terminal result;
- runtime/storage terminal results end ActivityKit as needs-attention even if
  the last readable snapshot is active;
- installing a different session stops the old goal runner and loads the new
  session's goal status; and
- a reconciliation error sets a visible goal error while leaving
  `goalsReady == true`.

- [ ] **Step 2: Confirm integration tests fail**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalChatModelTests \
  -only-testing:CovenPocketTests/ChatSurfaceTests
```

Expected: missing coordinator ownership and scene methods fail.

- [ ] **Step 3: Give the app-scoped root stable goal infrastructure**

The existing app-scoped `RootWindowState` owns one `GoalActivityManager` and one
`GoalExecutionCoordinator` bound to `chatState.model`. Add
`ChatModel.installGoalInfrastructure(activityManager:executionCoordinator:)`
as a one-time setup method; reject a second different installation in tests.
Add `@Published private(set) var goalActivityMessage: String?` to `ChatModel`.
Do not introduce multi-window ownership: `UIApplicationSupportsMultipleScenes`
remains false and the existing app-level state tests remain authoritative.

Give ActivityKit work a separate monotonic presentation revision:

```swift
private func enqueueGoalActivityUpdate(
    snapshot: GoalSnapshot?,
    result: GoalRunResult?,
    generation: UInt64,
    sequence: UInt64
) {
    goalActivityRevision &+= 1
    let revision = goalActivityRevision
    Task { @MainActor [weak self] in
        guard let self,
              goalRunGeneration == generation,
              acceptedGoalSequence == sequence
        else { return }
        let message: String?
        if let result {
            message = await goalActivityManager.finish(
                result,
                revision: revision
            )
        } else if let snapshot {
            message = await goalActivityManager.apply(
                snapshot,
                revision: revision
            )
        } else {
            return
        }
        guard goalRunGeneration == generation,
              acceptedGoalSequence == sequence,
              goalActivityRevision == revision
        else { return }
        goalActivityMessage = message
    }
}
```

Every accepted snapshot updates model state and enqueues `apply`. The reserved
terminal sequence applies `GoalRunResult`, calls
`goalExecutionCoordinator.goalExecutionEnded()`, and enqueues `finish`.
Clear advances the sequence and enqueues an immediate cleared result. A
terminal revision does not await a stale active operation; the manager's own
revision fence lets it end the activity immediately and prevents the stale
operation from reinstalling state after suspension. Reset and session
replacement advance `goalRunGeneration`; queued work checks generation,
callback sequence, and presentation revision around suspension points.
Accepting an active snapshot also calls
`goalExecutionCoordinator.goalExecutionStarted()`, so a callback delivered
after the scene already entered background still acquires finite background
time or immediately pauses when that claim is denied.

- [ ] **Step 4: Deliver launch and scene lifecycle**

Add `@Environment(\.scenePhase)` to `CovenPocketApp`. On the root view:

```swift
.task {
    await rootWindowState.chatState.model.prepareGoals()
}
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .active:
        rootWindowState.goalExecutionCoordinator.enterForeground()
    case .background:
        rootWindowState.goalExecutionCoordinator.enterBackground()
    case .inactive:
        break
    @unknown default:
        break
    }
}
```

After reconciliation, call `GoalActivityManager.endStaleActivities()`. A
reconciled active goal is already paused by Rust, so no stale activity survives
launch.

- [ ] **Step 5: Run integration and root ownership tests**

Run:

```bash
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:CovenPocketTests/GoalChatModelTests \
  -only-testing:CovenPocketTests/GoalExecutionCoordinatorTests \
  -only-testing:CovenPocketTests/GoalActivityManagerTests \
  -only-testing:CovenPocketTests/ChatSurfaceTests
```

Expected: all pass.

- [ ] **Step 6: Commit app lifecycle wiring**

Run:

```bash
git add app/Sources/Support/ChatModel.swift \
  app/Sources/Views/RootView.swift \
  app/Sources/CovenPocketApp.swift app/Tests/GoalChatModelTests.swift \
  app/Tests/ChatSurfaceTests.swift
git commit -m "feat: reconcile goals with app lifecycle"
```

---

### Task 20: Run focused review and hardening loops

**Files:**
- Modify only files implicated by verified review findings
- Modify: `.beads/issues.jsonl`
- Modify: `.beads/interactions.jsonl`

- [ ] **Step 1: Close completed implementation children**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
bd list --parent pocket-hoh --json
```

Close the children titled `Pocket on-device goal runtime` and
`Goal UI and bounded iOS lifecycle` with commit/test evidence. Claim
`Goal release hardening`.

- [ ] **Step 2: Run a focused Rust review**

Invoke a fresh code-review agent for:

```bash
git diff origin/main...HEAD -- rust
```

The review prompt must emphasize:

- SQLite path/sidecar safety;
- cancellation and pause/clear races;
- status transition correctness;
- token double-counting;
- hidden continuation persistence;
- tool allowlist expansion;
- delete/recovery atomicity; and
- errors that could look like success.

For each Critical or Important finding, first add a failing regression, then
fix, rerun the smallest gate, and commit.

- [ ] **Step 3: Run a focused Swift/ActivityKit review**

Invoke a fresh code-review agent for:

```bash
git diff origin/main...HEAD -- app project.yml
```

Emphasize:

- Rust callback actor hops and generation fencing;
- background-task identifier leaks/double-end;
- stale Live Activities;
- objective privacy;
- session switching;
- Companion non-regression;
- accessibility; and
- extension target membership/buildability.

Apply only verified findings with red/green tests and focused commits.

- [ ] **Step 4: Run a holistic branch review**

Invoke a new reviewer over `origin/main...HEAD`, including spec and issue #13.
Resolve every Critical or Important finding with tests. Repeat until a fresh
holistic review reports none.

- [ ] **Step 5: Record hardening evidence**

Append the reviewed commit range, finding dispositions, and focused gate
results to the hardening Bead. Commit Beads changes:

```bash
git add .beads/issues.jsonl .beads/interactions.jsonl
git commit -m "chore: record goal release hardening"
```

---

### Task 21: Run immutable release gates

**Files:**
- No planned source changes; fix failures in their owning task's files

- [ ] **Step 1: Freeze the candidate**

Run:

```bash
git status --short
git rev-parse HEAD
git diff --check origin/main...HEAD
```

Expected: clean worktree, one recorded candidate SHA, no whitespace errors.
Do not edit source after this point without restarting all affected gates.

- [ ] **Step 2: Run full Rust gates**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi
cargo check -p coven-pocket-ffi
cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings
cargo fmt --all --check
```

Expected: all tests pass and all checks exit zero.

- [ ] **Step 3: Rebuild the framework from the frozen SHA**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
./scripts/build-xcframework.sh
git diff --exit-code -- app/Sources/Generated/coven_pocket_ffi.swift
```

Expected: build succeeds and bindings are already current.

- [ ] **Step 4: Run strict Swift lint**

Run:

```bash
swiftlint lint --strict
```

Expected: zero violations.

- [ ] **Step 5: Run the full simulator suite**

Run:

```bash
xcodegen generate
xcodebuild test -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

Expected: every `CovenPocketTests` test passes.

- [ ] **Step 6: Build app and widget for a generic simulator**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: app and embedded goal widget extension build successfully.

- [ ] **Step 7: Exercise the real app, widget, and OS lifecycle**

Build and install the frozen candidate on a booted iPhone 16 simulator:

```bash
xcrun simctl list devices booted | rg 'iPhone 16' \
  || xcrun simctl boot 'iPhone 16'
xcrun simctl bootstatus 'iPhone 16' -b
DERIVED_DATA=/Users/buns/.copilot/session-state/657a4b31-a02e-4cb4-8020-c68a8bcf43e0/files/DerivedData-goal-release
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath "$DERIVED_DATA" build
xcrun simctl install booted \
  "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CovenPocket.app"
xcrun simctl launch booted ai.opencoven.pocket
```

With the simulator's Codex account connected, perform and record this checklist
in the hardening Bead:

1. Run `/goal Create goal-smoke.txt containing "smoke", then read it back and
   finish the goal.` Confirm one initiating user row, autonomous progress,
   completion, and a completed in-app card.
2. During a second goal, confirm the Lock Screen Live Activity (lock the
   simulator with **Device > Lock**) and compact/expanded Dynamic Island show
   only state, turns, time, and tokens—never objective or transcript text.
3. Pause, resume, and clear from the in-app card; confirm resume starts a fresh
   Live Activity and clear removes it.
4. Start `/goal --tokens 1 Create budget-smoke.txt.` Confirm the first
   completed turn records usage and ends budget-limited without offering
   Resume.
5. Start another goal, send the app to the background, and leave it there until
   iOS expires the finite background claim. Reopen and confirm the goal is
   paused rather than shown as still running.
6. Start another goal, terminate the process with
   `xcrun simctl terminate booted ai.opencoven.pocket`, relaunch with
   `xcrun simctl launch booted ai.opencoven.pocket`, and confirm launch
   reconciliation shows paused and removes the stale activity.
7. Disable Live Activities for Coven Pocket in Settings, start a goal, and
   confirm the in-app goal continues while external-progress unavailability is
   non-fatal and visible.
8. Switch sessions during a paused goal and confirm each session loads only its
   own goal; fork the session and confirm the fork has no goal.

Expected: every item matches the design. Any mismatch restarts the relevant
red/green task, review, and affected release gates.

- [ ] **Step 8: Run static boundary checks**

Run:

```bash
! git diff origin/main...HEAD -- rust/ffi/src/goals.rs rust/ffi/src/chat.rs \
  | rg '^\+.*(std::process|Command::new|PtyBash|BashTool|WebFetch|WebSearch)'
! git diff origin/main...HEAD -- app/Sources/Support/Goals app/GoalWidgetExtension \
  | rg '^\+.*(Process|PTY|BashTool|WebFetch|WebSearch)'
! rg -n 'objective|transcript|tool|filePath|account|familiar' \
  app/Sources/Support/Goals/GoalActivityAttributes.swift \
  app/GoalWidgetExtension
git status --short
```

Expected: no prohibited execution surface, no private content in activity
sources, and a clean worktree.

- [ ] **Step 9: Record release evidence**

Append the exact frozen SHA and gate counts/results to the hardening Bead. If
that changes Beads exports, commit only those exports, record the new SHA, and
rerun `git diff --check`; source gates remain attributable to the preceding
source SHA.

---

### Task 22: Release issue #13 and close durable tracking

**Files:**
- Modify: `ROADMAP.md`
- Modify: `.beads/issues.jsonl`
- Modify: `.beads/interactions.jsonl`

- [ ] **Step 1: Mark issue #13 complete in the roadmap**

Change the M3 `/goal` line to completed wording that states:

- on-device Codex only;
- durable pause/resume/clear and budget/runaway stops;
- finite iOS background continuation;
- privacy-safe Live Activity progress; and
- Companion goals remain daemon-owned/out of scope.

- [ ] **Step 2: Commit roadmap status**

Run:

```bash
git add ROADMAP.md
git commit -m "docs: mark on-device goals complete"
```

- [ ] **Step 3: Push and open the Pocket PR**

Run:

```bash
git push -u origin feat/on-device-goals
POCKET_PR=$(gh pr create --repo OpenCoven/coven-pocket \
  --base main --head feat/on-device-goals \
  --title "Add on-device goals with Live Activity progress" \
  --body "$(cat <<'BODY'
Closes #13.

## Summary
- run coven-code goals on-device through a path-scoped durable engine boundary
- pause/resume/clear safely across cancellation, session lifecycle, and iOS background expiration
- add an in-app goal card and privacy-safe Live Activity/limited Dynamic Island progress

## Boundaries
- Codex on-device only; Companion goals remain daemon-owned
- no shell, PTY, process, remote MCP, or broader tool permission
- Live Activity reports progress but does not imply indefinite background execution

## Validation
- full Rust tests/check/clippy/fmt
- regenerated XCFramework and stable UniFFI bindings
- strict SwiftLint
- full iOS simulator tests
- generic simulator app + widget build
- focused and holistic reviews with no Critical or Important findings
BODY
)")
printf '%s\n' "$POCKET_PR"
```

Expected: a PR URL that closes GitHub issue #13 on merge.

- [ ] **Step 4: Wait for CI and merge**

Run:

```bash
gh pr checks "$POCKET_PR" --watch
gh pr merge "$POCKET_PR" --repo OpenCoven/coven-pocket \
  --squash --delete-branch
MERGED_REV=$(gh pr view "$POCKET_PR" --repo OpenCoven/coven-pocket \
  --json mergeCommit --jq '.mergeCommit.oid')
test -n "$MERGED_REV"
gh issue view 13 --repo OpenCoven/coven-pocket \
  --json state --jq '.state'
```

Expected: CI passes, the PR merges, and issue #13 is `CLOSED`.

- [ ] **Step 5: Close Beads with merge evidence**

Run:

```bash
cd /Users/buns/Documents/GitHub/OpenCoven/coven-pocket
HARDENING_BEAD=$(bd list --parent pocket-hoh --json | jq -r \
  '.[] | select(.title == "Goal release hardening") | .id')
bd close "$HARDENING_BEAD" --reason \
  "Merged PR ${POCKET_PR} at ${MERGED_REV}; CI and immutable release gates passed." --json
bd close pocket-hoh --reason \
  "Completed by merged PR ${POCKET_PR} (${MERGED_REV}); GitHub issue #13 closed." --json
bd list --parent pocket-hoh --json
git status --short --branch
```

Expected: parent and all children are closed. The only possible local diff is
the post-merge Beads closure export; preserve it for the next tracking commit
under the repository's conservative profile.

- [ ] **Step 6: Remove the upstream worktree**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code worktree remove \
  /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code worktree prune
```

Expected: the merged upstream worktree is removed without touching the main
upstream checkout.
