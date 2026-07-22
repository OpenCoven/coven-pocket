# Development Rules

Agent-facing rules for working on Coven Pocket. Follows the conventions of
[coven-code/AGENTS.md](https://github.com/OpenCoven/coven-code/blob/main/AGENTS.md)
where they apply.

## Conversational style

- Keep answers short and concise
- No emojis in commits, issues, PR comments, or code
- Technical prose only

## Layout

- `app/` — SwiftUI sources. Xcode project is **generated**: edit `project.yml`,
  never commit `CovenPocket.xcodeproj`.
- `rust/ffi` — the only hand-written Rust crate; a thin UniFFI surface over
  coven-code engine crates. Engine logic lives upstream in coven-code — do not
  fork engine behavior here; upstream it.
- `app/Sources/Generated/` — UniFFI-generated Swift. Never edit; regenerate with
  `./scripts/build-xcframework.sh`.

## Engine pinning

- coven-code crates are pinned by git `rev` in `rust/Cargo.toml`. Bumping the pin
  is a deliberate act: update the rev, run the full build, note engine-visible
  changes in the commit message.
- Internal crate names stay `claurst-*` (upstream merge-friendliness). User-visible
  surfaces say Coven Pocket / coven-code.

## Code quality

- Rust: no `.unwrap()` / `.expect()` on fallible paths outside tests; propagate
  `Result`. No `unsafe` without a `// SAFETY:` comment.
- Swift: swiftlint clean (`swiftlint lint --strict`); Swift 6 concurrency —
  UniFFI callbacks arrive on Rust threads, hop to `@MainActor` before touching UI.
- iOS sandbox boundary is a hard rule: no process spawning, no PTY, no shell
  tools on-device. Anything needing execution routes to companion mode (daemon).

## Licensing boundary

This repo is GPL-3.0 (links GPL engine crates). Only GPL-compatible dependencies
may be added. Read `docs/LICENSING.md` before touching distribution, store
metadata, or adding dependencies.

## Commands

- Rust check: `cd rust && cargo check -p coven-pocket-ffi`
- Rust lint: `cd rust && cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings && cargo fmt --all --check`
- Full framework build: `./scripts/build-xcframework.sh`
- App build: `xcodegen generate && xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket -destination 'generic/platform=iOS Simulator' build`

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
