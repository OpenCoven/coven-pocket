# Worktree Consolidation Design

## Goal

Consolidate completed work into each repository's `main` branch without merging
unfinished or stale changes. Preserve the active remote-MCP worktree and leave
both repositories with no unexplained dirty worktrees.

## Pocket consolidation

- Keep the active `feat/remote-mcp-servers` worktree and fast-forward its clean
  baseline to current `origin/main`.
- Remove clean worktrees whose exact heads were already merged by PRs #33,
  #34, #37, and #38.
- Discard the stale on-device-goal plan edits because they are incomplete as an
  execution record and duplicate merged implementation details.
- Remove `rust/ffi/target/` as generated build output.
- Export the live Beads state after this consolidation task closes, then merge
  that export through a dedicated Pocket PR.
- Switch the primary Pocket checkout to current `main` after its exported Beads
  changes are safely merged.

## Engine consolidation

Create a clean branch from current coven-code `main` and port only the bounded
goal-continuation race fix:

- make active-to-paused outcome classification atomic;
- capture and use the initial goal ID for completed-turn accounting, runaway
  pause, and budget-limit transitions;
- add a source-compatible continuation lease;
- revalidate the lease before injecting and immediately before dispatching the
  autonomous continuation turn;
- remove an injected continuation message if the final revalidation fails.

Existing continuation APIs remain available and map through the guarded
implementation.

## Unfinished engine work

The larger stream/query refactor is not merge-ready. Preserve it as a clearly
labeled WIP snapshot and create upstream follow-up issues for:

1. lossless stream accumulation, explicit terminal events, usage accounting,
   unique attempt identity, and cancellation draining; and
2. durable abnormal-terminal history, compaction cancellation, retry output,
   tool-result closure, and TUI durable-message handling.

The WIP snapshot must not revert current `main` security or test-serialization
changes and must not be presented as mergeable.

## Validation

The goal-race branch requires focused deterministic race tests, affected-crate
tests, workspace check, strict Clippy, formatting, and diff checks. It also
requires independent specification and code-quality reviews before merge.

Pocket consolidation requires a scoped Beads diff, clean diff check, passing PR
CI, and confirmation that the primary checkout and retained remote-MCP worktree
are clean and based on current `main`.

## Failure handling

- Do not merge the engine branch if lease revalidation cannot prevent a
  replacement goal from reaching query dispatch.
- Do not delete a worktree until its unique changes are merged, archived, or
  explicitly classified as generated/duplicate.
- Do not modify the active remote-MCP implementation beyond fast-forwarding its
  clean baseline.
