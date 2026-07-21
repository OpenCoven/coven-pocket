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
