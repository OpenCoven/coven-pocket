# Worktree Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate completed Pocket and coven-code work into `main`, merge the bounded goal-continuation race fix, archive unfinished engine work safely, and leave only the active remote-MCP worktree.

**Architecture:** Preserve the unfinished engine refactor on a WIP branch created from current `main`, but merge only the independent goal identity/dispatch lease fix. Complete Pocket consolidation through a scoped Beads export PR, then clean merged branches and worktrees without touching active remote-MCP implementation work.

**Tech Stack:** Rust, Tokio, rusqlite, Git worktrees, GitHub CLI, Beads

---

### Task 1: Preserve and classify unfinished engine work

**Files:**
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/api/src/lib.rs`
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/api/src/providers/anthropic.rs`
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/core/Cargo.toml`
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/core/src/goal.rs`
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/query/src/compact.rs`
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/query/src/goal_loop.rs`
- Read from: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path/src-rust/crates/query/src/lib.rs`
- Archive in: `/Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening`

- [ ] **Step 1: Capture only post-PR #175 changes**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path \
  diff --binary 5c6346ff204398983acefdc0077dcb32606ec9b6 -- \
  src-rust/crates/api/src/lib.rs \
  src-rust/crates/api/src/providers/anthropic.rs \
  src-rust/crates/core/Cargo.toml \
  src-rust/crates/core/src/goal.rs \
  src-rust/crates/query/src/compact.rs \
  src-rust/crates/query/src/goal_loop.rs \
  src-rust/crates/query/src/lib.rs \
  > /tmp/coven-code-post-pr175.patch
```

Expected: the patch excludes `core/src/lib.rs` and `core/src/memdir.rs`, whose
differences would revert current-main hardening.

- [ ] **Step 2: Create a clean WIP archive branch**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code worktree add \
  /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  -b wip/post-pr175-stream-query-hardening origin/main
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  apply --3way /tmp/coven-code-post-pr175.patch
```

Expected: only the seven explicitly listed source/manifests are modified.

- [ ] **Step 3: Verify the snapshot does not revert current main**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  diff --name-only
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  diff --check
```

Expected: no `core/src/lib.rs` or `core/src/memdir.rs`; diff check passes.

- [ ] **Step 4: Commit and push the explicitly non-mergeable snapshot**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  add src-rust/crates/api/src/lib.rs \
      src-rust/crates/api/src/providers/anthropic.rs \
      src-rust/crates/core/Cargo.toml \
      src-rust/crates/core/src/goal.rs \
      src-rust/crates/query/src/compact.rs \
      src-rust/crates/query/src/goal_loop.rs \
      src-rust/crates/query/src/lib.rs
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  commit -m "wip: preserve post-PR 175 stream hardening" \
  -m "Not merge-ready: tracked by follow-up issues." \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  push -u origin wip/post-pr175-stream-query-hardening
```

Expected: the original dirty work is durably recoverable without presenting it
as merge-ready.

- [ ] **Step 5: Create two upstream follow-up issues**

Run:

```bash
gh issue create --repo OpenCoven/coven-code \
  --title "Harden provider stream accumulation and attempt identity" \
  --body "$(cat <<'BODY'
Preserved WIP: `wip/post-pr175-stream-query-hardening`.

Required before merge:
- preserve tool-start input and incomplete JSON losslessly;
- require explicit terminal events for every provider path;
- drain queued cancellation events;
- account known usage on cancellation and stalls;
- generate unique transcript UUIDs per attempt;
- cover indexed text, thinking signatures, tool blocks, EOF, and provider errors.
BODY
)"

gh issue create --repo OpenCoven/coven-code \
  --title "Finish durable abnormal query termination and compaction handling" \
  --body "$(cat <<'BODY'
Preserved WIP: `wip/post-pr175-stream-query-hardening`.

Required before merge:
- finalize substantive stalled/cancelled output exactly once;
- close unmatched tool uses with adjacent error results;
- make proactive, reactive, and emergency compaction cancellation-safe;
- preserve retry output without empty durable assistants;
- handle `DurableMessage` consistently in the TUI;
- pass focused and workspace gates plus fresh spec/code reviews.
BODY
)"
```

Expected: two issue URLs linked to the WIP branch.

---

### Task 2: Add atomic pause outcomes and replacement-safe goal guards

**Files:**
- Modify: `/Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust/crates/core/src/goal.rs`
- Modify: `/Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust/crates/query/src/goal_loop.rs`
- Test: the existing `#[cfg(test)]` modules in both files

- [ ] **Step 1: Create a clean implementation worktree**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code worktree add \
  /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  -b fix/goal-continuation-lease origin/main
```

Expected: clean worktree at current `origin/main`.

- [ ] **Step 2: Write failing atomic-pause tests**

Add tests in `core/src/goal.rs`:

```rust
#[test]
fn strict_pause_reports_whether_it_transitioned_the_active_goal() {
    let store = open_tmp();
    store.set_goal("session", "work", None).unwrap();

    assert!(store.pause_active_goal_with_outcome("session").unwrap());
    assert!(!store.pause_active_goal_with_outcome("session").unwrap());

    store.set_goal("complete", "finished", None).unwrap();
    store.complete_active_goal("complete").unwrap();
    assert!(matches!(
        store.pause_active_goal_with_outcome("complete"),
        Err(GoalError::NotActive { session_id }) if session_id == "complete"
    ));
}

#[test]
fn expected_goal_strict_pause_preserves_replacement() {
    let store = open_tmp();
    let original = store.set_goal("session", "original", None).unwrap();
    store.pause_active_goal_for_goal_with_outcome("session", &original.id)
        .unwrap();
    assert!(!store
        .pause_active_goal_for_goal_with_outcome("session", &original.id)
        .unwrap());

    let replacement = store.set_goal("session", "replacement", None).unwrap();
    assert!(matches!(
        store.pause_active_goal_for_goal_with_outcome("session", &original.id),
        Err(GoalError::Replaced { .. })
    ));
    assert_eq!(
        store.try_get_goal("session").unwrap().unwrap().id,
        replacement.id
    );
}
```

- [ ] **Step 3: Confirm the tests fail**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst-core strict_pause -- --nocapture
```

Expected: compilation fails because the outcome methods do not exist.

- [ ] **Step 4: Implement transaction-backed outcome methods**

Keep the existing compatibility methods and add:

```rust
pub fn pause_active_goal(&self, session_id: &str) -> Result<(), GoalError> {
    self.pause_active_goal_with_outcome(session_id).map(|_| ())
}

pub fn pause_active_goal_with_outcome(
    &self,
    session_id: &str,
) -> Result<bool, GoalError> {
    let transaction = self.immediate_transaction()?;
    let goal = Self::transaction_goal(&transaction, session_id)?
        .ok_or_else(|| GoalError::NotFound {
            session_id: session_id.to_string(),
        })?;
    if goal.status == GoalStatus::Paused {
        return Ok(false);
    }
    if goal.status != GoalStatus::Active {
        return Err(GoalError::NotActive {
            session_id: session_id.to_string(),
        });
    }
    let updated = transaction.execute(
        "UPDATE goals SET status = 'paused', updated_at_ms = ?1
         WHERE session_id = ?2 AND id = ?3 AND status = 'active'",
        rusqlite::params![
            Self::sqlite_i64(Self::now_ms(), "timestamp")?,
            session_id,
            goal.id,
        ],
    ).map_err(|error| GoalError::Db(error.to_string()))?;
    if updated != 1 {
        return Err(GoalError::NotActive {
            session_id: session_id.to_string(),
        });
    }
    transaction.commit().map_err(|error| GoalError::Db(error.to_string()))?;
    Ok(true)
}
```

Implement `pause_active_goal_for_goal_with_outcome` with the same immediate
transaction, exact ID check, paused `Ok(false)`, and active guarded update.

- [ ] **Step 5: Write failing replacement-race tests**

Add deterministic test hooks before completed-turn record, runaway pause, and
budget-limit transition. Add explicit/default/expected-ID tests that replace
the goal in those hooks and assert:

```rust
assert!(matches!(result, Err(GoalError::Replaced { .. })));
let replacement = store.try_get_goal("session").unwrap().unwrap();
assert_eq!(replacement.objective, "replacement objective");
assert_eq!(replacement.status, GoalStatus::Active);
assert_eq!(replacement.turns_used, 0);
```

For compatibility wrappers, assert `GoalContinuation::Stop` with an error
message containing `replaced`.

- [ ] **Step 6: Confirm replacement tests fail**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst-query goal_loop::tests:: -- --nocapture
```

Expected: at least the default/explicit replacement tests fail because
unguarded operations mutate the replacement.

- [ ] **Step 7: Route every continuation through the captured goal ID**

Add:

```rust
fn current_goal(
    store: &GoalStore,
    session_id: &str,
    expected_goal_id: Option<&str>,
) -> Result<Goal, GoalError> {
    let goal = store.try_get_goal(session_id)?
        .ok_or_else(|| GoalError::NotFound {
            session_id: session_id.to_string(),
        })?;
    if let Some(expected_goal_id) = expected_goal_id {
        if goal.id != expected_goal_id {
            return Err(GoalError::Replaced {
                session_id: session_id.to_string(),
                expected_goal_id: expected_goal_id.to_string(),
                actual_goal_id: goal.id,
            });
        }
    }
    Ok(goal)
}
```

In the legacy store function, capture `current_goal(..., None)?.id` before any
test hook and call the expected-ID variants for completed-turn record,
runaway pause, and budget-limit transition. Use the outcome-aware pause method;
when it returns `false`, reload and return the actual terminal status.

- [ ] **Step 8: Run focused tests**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst-core goal::tests::
cargo test -p claurst-query goal_loop::tests::
```

Expected: all core goal and query goal-loop tests pass.

- [ ] **Step 9: Commit the storage/guard changes**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  add src-rust/crates/core/src/goal.rs src-rust/crates/query/src/goal_loop.rs
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  commit -m "fix(goals): guard continuation transitions by goal identity" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Add a source-compatible continuation lease

**Files:**
- Modify: `/Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust/crates/query/src/goal_loop.rs`
- Modify: `/Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust/crates/query/src/lib.rs`

- [ ] **Step 1: Write failing lease tests**

Add tests:

```rust
#[test]
fn continuation_lease_revalidates_only_the_same_active_goal() {
    let dir = tempfile::tempdir().unwrap();
    let path = goal_path(&dir);
    let store = GoalStore::open(&path).unwrap();
    let goal = store.set_goal("session", "finish", None).unwrap();
    let lease = GoalContinuationLease::new(
        path.clone(),
        "session".to_string(),
        goal.id.clone(),
        "continue".to_string(),
    );

    assert_eq!(
        revalidate_goal_continuation_lease(&lease).unwrap().id,
        goal.id
    );
    store.set_goal("session", "replacement", None).unwrap();
    assert!(matches!(
        revalidate_goal_continuation_lease(&lease),
        Err(GoalError::Replaced { .. })
    ));
}

#[test]
fn paused_goal_invalidates_continuation_lease() {
    let dir = tempfile::tempdir().unwrap();
    let path = goal_path(&dir);
    let store = GoalStore::open(&path).unwrap();
    let goal = store.set_goal("session", "finish", None).unwrap();
    let lease = GoalContinuationLease::new(
        path,
        "session".to_string(),
        goal.id,
        "continue".to_string(),
    );
    store.pause_active_goal("session").unwrap();
    assert!(matches!(
        revalidate_goal_continuation_lease(&lease),
        Err(GoalError::NotActive { .. })
    ));
}
```

- [ ] **Step 2: Confirm the tests fail**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst-query continuation_lease -- --nocapture
```

Expected: compilation fails because lease types/functions do not exist.

- [ ] **Step 3: Implement the additive lease types**

Add:

```rust
#[derive(Debug, Clone)]
pub struct GoalContinuationLease {
    goal_db_path: PathBuf,
    session_id: String,
    goal_id: String,
    message: String,
}

impl GoalContinuationLease {
    pub fn new(
        goal_db_path: PathBuf,
        session_id: String,
        goal_id: String,
        message: String,
    ) -> Self {
        Self { goal_db_path, session_id, goal_id, message }
    }

    pub fn goal_id(&self) -> &str { &self.goal_id }
    pub fn message(&self) -> &str { &self.message }
}

#[derive(Debug)]
pub enum LeasedGoalContinuation {
    Continue(GoalContinuationLease),
    Stop { reason: StopReason },
    NoGoal,
}
```

Add:

```rust
pub fn revalidate_goal_continuation_lease(
    lease: &GoalContinuationLease,
) -> Result<Goal, GoalError> {
    let store = GoalStore::open(&lease.goal_db_path)?;
    let goal = current_goal(&store, &lease.session_id, Some(&lease.goal_id))?;
    if goal.status != GoalStatus::Active {
        return Err(GoalError::NotActive {
            session_id: lease.session_id.clone(),
        });
    }
    Ok(goal)
}
```

Add `check_and_continue_goal_for_goal_with_lease`. It runs the same default-path
expected-ID accounting and maps a `Continue { message }` result to a lease.
Keep `check_and_continue_goal_for_goal` source-compatible by mapping the leased
result back to `GoalContinuation`.

- [ ] **Step 4: Export the additive API**

Update `query/src/lib.rs`:

```rust
pub use goal_loop::{
    check_and_continue_goal,
    check_and_continue_goal_at_path,
    check_and_continue_goal_at_path_for_goal,
    check_and_continue_goal_for_goal,
    check_and_continue_goal_for_goal_with_lease,
    mark_goal_complete,
    revalidate_goal_continuation_lease,
    GoalContinuation,
    GoalContinuationLease,
    LeasedGoalContinuation,
    StopReason,
};
```

- [ ] **Step 5: Run lease and compatibility tests**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst-query continuation_lease
cargo test -p claurst-query goal_loop::tests::
```

Expected: lease tests and all existing compatibility tests pass.

- [ ] **Step 6: Commit the lease API**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  add src-rust/crates/query/src/goal_loop.rs src-rust/crates/query/src/lib.rs
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  commit -m "feat(goals): add a guarded continuation lease" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Revalidate the lease at CLI dispatch

**Files:**
- Modify: `/Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust/crates/cli/src/main.rs`

- [ ] **Step 1: Add failing CLI helper tests**

Add pure helper tests for:

```rust
#[test]
fn expected_goal_baseline_rejects_replacement() {
    // Use a temporary COVEN_CODE_HOME under the existing env lock.
    // Create original, replace it, then request a baseline for original ID.
    assert!(matches!(
        capture_goal_turn_baseline_for_goal("session", "original-id", 10),
        Err(claurst_core::GoalError::Replaced { .. })
    ));
}

#[test]
fn remove_message_uuid_removes_only_injected_continuation() {
    let keep = Message::user("keep");
    let remove = Message::user("continue");
    let remove_id = remove.uuid.clone().unwrap();
    let mut messages = vec![keep.clone(), remove];

    assert!(remove_message_by_uuid(&mut messages, &remove_id));
    assert_eq!(messages, vec![keep]);
}
```

- [ ] **Step 2: Confirm the tests fail**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst goal_ -- --nocapture
```

Expected: compilation fails because the exact-ID baseline and removal helpers
do not exist.

- [ ] **Step 3: Add exact-ID baseline and cleanup helpers**

Implement:

```rust
fn capture_goal_turn_baseline_for_goal(
    session_id: &str,
    expected_goal_id: &str,
    tracker_total: u64,
) -> Result<GoalTurnBaseline, claurst_core::GoalError> {
    let store = claurst_core::GoalStore::open(
        &claurst_core::GoalStore::default_path(),
    )?;
    let goal = store.try_get_goal(session_id)?.ok_or_else(|| {
        claurst_core::GoalError::NotFound {
            session_id: session_id.to_string(),
        }
    })?;
    if goal.id != expected_goal_id {
        return Err(claurst_core::GoalError::Replaced {
            session_id: session_id.to_string(),
            expected_goal_id: expected_goal_id.to_string(),
            actual_goal_id: goal.id,
        });
    }
    if goal.status != claurst_core::GoalStatus::Active {
        return Err(claurst_core::GoalError::NotActive {
            session_id: session_id.to_string(),
        });
    }
    Ok(GoalTurnBaseline {
        goal_id: expected_goal_id.to_string(),
        tracker_total,
        started_at: std::time::Instant::now(),
    })
}

fn remove_message_by_uuid(messages: &mut Vec<Message>, uuid: &str) -> bool {
    let before = messages.len();
    messages.retain(|message| message.uuid.as_deref() != Some(uuid));
    messages.len() != before
}
```

- [ ] **Step 4: Use the leased continuation result**

Replace `check_and_continue_goal_for_goal` with
`check_and_continue_goal_for_goal_with_lease`. On `Continue(lease)`:

1. call `revalidate_goal_continuation_lease(&lease)` before creating the user
   message;
2. create and retain the continuation message UUID;
3. capture the next baseline with
   `capture_goal_turn_baseline_for_goal(..., lease.goal_id(), ...)`;
4. store the UUID in `pending_goal_continuation_uuid`.

Do not inject or dispatch if the first revalidation fails.

- [ ] **Step 5: Revalidate inside the spawned task**

Before `run_query_loop`, add:

```rust
if let Err(error) =
    claurst_query::revalidate_goal_continuation_lease(&lease_for_task)
{
    let mut guarded_messages = msgs_arc_clone.lock().await;
    remove_message_by_uuid(&mut guarded_messages, &continuation_uuid_for_task);
    return QueryOutcome::Error(claurst_core::error::ClaudeError::Other(
        format!("Goal continuation lease expired before dispatch: {error}"),
    ));
}
```

After the task completes and `messages` is reloaded from `msgs_arc`, if
`pending_goal_continuation_uuid` is absent from the reloaded vector, call:

```rust
app.replace_messages(messages.clone());
session.messages = messages.clone();
```

Then clear `pending_goal_continuation_uuid`. This removes the injected message
from local history, session history, and TUI state when the final lease check
fails.

- [ ] **Step 6: Add a replacement-before-dispatch regression**

Use a test hook immediately before the spawned-task revalidation. Replace the
goal in the hook and assert:

- `run_query_loop` is not called;
- the replacement remains active and has zero progress;
- the continuation UUID is absent from the shared messages;
- the returned outcome is `QueryOutcome::Error`.

- [ ] **Step 7: Run CLI and goal tests**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo test -p claurst goal_accounting
cargo test -p claurst goal_continuation
cargo test -p claurst-query goal_loop::tests::
```

Expected: all targeted tests pass.

- [ ] **Step 8: Commit CLI dispatch fencing**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  add src-rust/crates/cli/src/main.rs
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  commit -m "fix(cli): revalidate goal continuation before dispatch" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Validate, review, and merge the engine fix

**Files:**
- Review all changes under `/Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease`

- [ ] **Step 1: Run immutable engine gates**

Run:

```bash
cd /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease/src-rust
cargo check --workspace --locked
cargo clippy -p claurst-core -p claurst-query -p claurst --all-targets -- -D warnings
cargo fmt --all --check
cargo test -p claurst-core goal::tests::
cargo test -p claurst-query goal_loop::tests::
cargo test -p claurst goal_
git -C .. diff --check
```

Expected: every command passes.

- [ ] **Step 2: Run specification review**

Dispatch a fresh read-only reviewer against the approved consolidation spec.
Resolve every missing requirement and re-run Step 1.

- [ ] **Step 3: Run code-quality review**

Dispatch a fresh read-only code reviewer focused on SQLite races, replacement
identity, dispatch timing, message cleanup, and source compatibility. Resolve
every high-confidence issue and re-run Step 1.

- [ ] **Step 4: Push and open the engine PR**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-code/goal-continuation-lease \
  push -u origin fix/goal-continuation-lease
gh pr create --repo OpenCoven/coven-code \
  --base main --head fix/goal-continuation-lease \
  --title "fix(goals): fence autonomous continuation dispatch" \
  --body "$(cat <<'BODY'
## Summary
- guard goal accounting and terminal transitions by the original goal ID
- add a source-compatible continuation lease
- revalidate immediately before autonomous query dispatch

## Validation
- focused core/query/CLI goal tests
- workspace check, strict Clippy, rustfmt, and diff check
BODY
)"
```

- [ ] **Step 5: Wait for green CI and merge**

Run:

```bash
ENGINE_PR=$(gh pr view --repo OpenCoven/coven-code \
  fix/goal-continuation-lease --json number --jq .number)
gh pr checks --repo OpenCoven/coven-code --watch "$ENGINE_PR"
gh pr merge --repo OpenCoven/coven-code --merge --delete-branch "$ENGINE_PR"
```

Expected: PR is merged and current `origin/main` contains the lease fix.

---

### Task 6: Remove the stale engine worktree

**Files:**
- Remove: `/Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path`

- [ ] **Step 1: Verify preservation and merge evidence**

Run:

```bash
gh issue list --repo OpenCoven/coven-code --state open --search \
  "post-pr175 stream hardening"
git -C /Users/buns/.config/superpowers/worktrees/coven-code/post-pr175-stream-query-hardening \
  status --short --branch
gh pr view --repo OpenCoven/coven-code fix/goal-continuation-lease \
  --json state,mergeCommit
```

Expected: WIP branch is pushed and clean, follow-up issues exist, lease PR is
merged.

- [ ] **Step 2: Remove the stale dirty worktree**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code worktree remove \
  --force /Users/buns/Documents/GitHub/OpenCoven/coven-code-goal-path
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code branch -D \
  feat/path-scoped-goals
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-code pull --ff-only
```

Expected: coven-code retains only clean `main`, the clean WIP archive worktree,
and any explicitly active worktrees.

---

### Task 7: Publish final Pocket Beads state and clean the primary checkout

**Files:**
- Modify: `.beads/issues.jsonl`
- Modify: `.beads/interactions.jsonl`
- Existing commit: `docs/superpowers/specs/2026-08-01-worktree-consolidation-design.md`
- Existing plan: `docs/superpowers/plans/2026-08-01-worktree-consolidation.md`

- [ ] **Step 1: Record engine outcomes in Beads**

Run:

```bash
bd update pocket-62j --append-notes \
  "Archived unfinished engine stream/query work on wip/post-pr175-stream-query-hardening with upstream follow-up issues. Merged the bounded goal continuation lease PR and removed the stale dirty engine worktree." --json
```

- [ ] **Step 2: Close the consolidation Bead**

Run:

```bash
bd close pocket-62j --reason \
  "Merged safe engine goal-race fixes, archived incomplete engine work, removed merged/stale worktrees, and preserved the active remote-MCP worktree." --json
```

- [ ] **Step 3: Refresh the clean Pocket worktree exports**

Copy the final passive exports:

```bash
cp /Users/buns/Documents/GitHub/OpenCoven/coven-pocket/.beads/issues.jsonl \
  /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state/.beads/issues.jsonl
cp /Users/buns/Documents/GitHub/OpenCoven/coven-pocket/.beads/interactions.jsonl \
  /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state/.beads/interactions.jsonl
```

Verify:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state \
  diff --check
git -C /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state \
  status --short --branch
```

Expected: only Beads exports and this plan remain uncommitted after the already
committed design.

- [ ] **Step 4: Commit and publish Pocket consolidation**

Run:

```bash
git -C /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state \
  add .beads/issues.jsonl .beads/interactions.jsonl \
      docs/superpowers/plans/2026-08-01-worktree-consolidation.md
git -C /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state \
  commit -m "chore: consolidate completed worktrees" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git -C /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state \
  push -u origin chore/consolidate-worktree-state
gh pr create --repo OpenCoven/coven-pocket \
  --base main --head chore/consolidate-worktree-state \
  --title "chore: consolidate completed worktrees" \
  --body "$(cat <<'BODY'
## Summary
- persist final Beads state for completed goal/worktree cleanup
- document the safe engine consolidation boundary and execution plan
- retain only the active remote-MCP worktree
BODY
)"
```

- [ ] **Step 5: Merge Pocket consolidation**

Run:

```bash
POCKET_PR=$(gh pr view --repo OpenCoven/coven-pocket \
  chore/consolidate-worktree-state --json number --jq .number)
gh pr checks --repo OpenCoven/coven-pocket --watch "$POCKET_PR"
gh pr merge --repo OpenCoven/coven-pocket --merge --delete-branch "$POCKET_PR"
```

- [ ] **Step 6: Clean and switch the primary Pocket checkout**

After the PR merges:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket restore \
  .beads/issues.jsonl .beads/interactions.jsonl
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket switch main
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket pull --ff-only
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket branch -D \
  fix/goal-background-pause
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket push origin \
  --delete fix/goal-background-pause
```

Expected: primary Pocket checkout is clean on current `main`.

- [ ] **Step 7: Remove the completed Pocket consolidation worktree**

Run:

```bash
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket worktree remove \
  /Users/buns/.config/superpowers/worktrees/coven-pocket/consolidate-worktree-state
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket branch -D \
  chore/consolidate-worktree-state
git -C /Users/buns/Documents/GitHub/OpenCoven/coven-pocket worktree list
```

Expected: only the clean primary checkout and active
`feat/remote-mcp-servers` worktree remain.
