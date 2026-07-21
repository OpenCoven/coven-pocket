# Coven Pocket

**Coven Code in your pocket.** An iOS client for the [OpenCoven](https://opencoven.ai)
agentic coding ecosystem, built on the same Rust engine as
[coven-code](https://github.com/OpenCoven/coven-code).

> **Status: pre-alpha.** M0 foundation — Rust engine crates compile for iOS and the
> spike app streams a completion end-to-end. Nothing here is stable.

## What it is

A hybrid agentic coding app:

- **Standalone mode** — bring your own Anthropic key (Codex OAuth planned). The
  coven-code engine runs on-device: agentic loop, sessions, memory, diffs, and a
  sandbox-safe tool profile (file tools; no shell — iOS forbids subprocesses).
- **Companion mode** (planned) — pair with the [Coven daemon](https://github.com/OpenCoven/coven)
  on your Mac or server to attach, steer, and approve full-capability sessions
  remotely.

Local-first, no telemetry, no OpenCoven servers in the path — requests go straight
from the device to your provider.

## Architecture

```
app/            SwiftUI app (iOS 17+)
rust/ffi        coven-pocket-ffi: UniFFI surface over coven-code crates
                (claurst-core, claurst-api pinned by git rev)
scripts/        XCFramework + Swift bindings generation
```

The engine crates keep their upstream `claurst-*` names (see coven-code's
[fork notes](https://github.com/OpenCoven/coven-code#opencoven-fork-notes)).

## Build

Requirements: Xcode 16+, Rust with `aarch64-apple-ios` + `aarch64-apple-ios-sim`
targets, [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-xcframework.sh        # builds Rust core + Swift bindings
xcodegen generate                     # produces CovenPocket.xcodeproj
open CovenPocket.xcodeproj            # build & run the CovenPocket scheme
```

Rust-only check (fast inner loop):

```bash
cd rust && cargo check -p coven-pocket-ffi
```

## License

GPL-3.0 — this app links GPL-3.0 engine crates from coven-code (itself derived
from [Claurst](https://github.com/Kuberwastaken/claurst) by Kuber Mehta). See
[`LICENSE.md`](LICENSE.md) and the [licensing decision record](docs/LICENSING.md)
for what that means for distribution.
