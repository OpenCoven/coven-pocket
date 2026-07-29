# Daemon-Backed Claude Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Chat's Anthropic API-key path with a paired-daemon Claude stream session while preserving on-device Codex and the Playground.

**Architecture:** Extend the existing bounded Rust daemon client with typed session launch, then add a Swift companion-chat model behind an injectable client protocol. `ChatView` selects either the new daemon model or the existing Codex model; daemon output remains event-ledger authoritative and no failure falls back to provider HTTP.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, Rust, Tokio, Serde, UniFFI, Coven daemon `coven.daemon.v1`

---

## File Structure

- Modify `rust/ffi/src/remote.rs`: serialize and parse daemon session launches.
- Modify `rust/ffi/src/lib.rs`: export the launch operation through `PocketEngine`.
- Modify `app/Sources/Support/RemoteTranscript.swift`: distinguish one-shot session results from stream turn results.
- Modify `app/Sources/Support/ChatTypes.swift`: define the app-level Chat backend and remove Chat API-key state.
- Modify `app/Sources/Support/ChatModel.swift`: make the existing local model Codex-only.
- Create `app/Sources/Support/CompanionChatModel.swift`: own pairing gates, daemon session lifecycle, polling, and remote Chat rows.
- Create `app/Tests/CompanionChatTests.swift`: deterministic daemon-chat unit tests with an in-memory client.
- Modify `app/Tests/RemoteAttachTests.swift`: lock result semantics for one-shot and stream views.
- Modify `app/Tests/ChatSurfaceTests.swift`: lock backend settings and absence of Anthropic key usage from Chat.
- Modify `app/Sources/Views/ChatSettingsView.swift`: show backend-specific Codex or daemon settings.
- Modify `app/Sources/Views/ChatView.swift`: select models, render daemon approvals, and route Chat actions.
- Modify `app/Sources/Views/RemoteSessionsView.swift`: support presentation from the Chat history sheet.
- Modify `app/Sources/Intents/CovenIntents.swift`: clarify that optional iOS workspaces apply only to on-device Codex.
- Modify `ROADMAP.md`: mark the approved M2 item complete after verification.

### Task 1: Typed daemon session launch

**Files:**
- Modify: `rust/ffi/src/remote.rs`
- Modify: `rust/ffi/src/lib.rs`

- [ ] **Step 1: Add the failing Rust launch contract test**

Add this test beside the existing remote transport tests:

```rust
#[tokio::test]
async fn launches_claude_stream_session_with_explicit_host_root() {
    let (port, rx) = serve_once(
        "HTTP/1.1 201 Created",
        r#"{"id":"s-claude","project_root":"/srv/repo","harness":"claude",
            "title":"Fix tests","status":"running",
            "created_at":"2026-07-29T00:00:00Z",
            "updated_at":"2026-07-29T00:00:00Z"}"#,
    )
    .await;

    let session = launch(
        "127.0.0.1",
        port,
        "/srv/repo",
        "Fix tests",
        "Fix tests",
        TIMEOUT,
    )
    .await
    .unwrap();

    assert_eq!(session.id, "s-claude");
    assert_eq!(session.harness, "claude");
    assert_eq!(session.project_root, "/srv/repo");

    let request = rx.await.unwrap();
    assert!(
        request.starts_with("POST /api/v1/sessions HTTP/1.1"),
        "got: {request}"
    );
    let body = request.split_once("\r\n\r\n").unwrap().1;
    let payload: serde_json::Value = serde_json::from_str(body).unwrap();
    assert_eq!(payload["projectRoot"], "/srv/repo");
    assert_eq!(payload["cwd"], "/srv/repo");
    assert_eq!(payload["harness"], "claude");
    assert_eq!(payload["prompt"], "Fix tests");
    assert_eq!(payload["title"], "Fix tests");
    assert_eq!(payload["launchMode"], "stream");
    assert!(payload.get("apiKey").is_none());
}

#[tokio::test]
async fn launch_surfaces_the_daemon_auth_failure_without_fallback() {
    let (port, _rx) = serve_once(
        "HTTP/1.1 500 Internal Server Error",
        r#"{"error":{"code":"launch_failed","message":"claude is not signed in"}}"#,
    )
    .await;

    let error = launch(
        "127.0.0.1",
        port,
        "/srv/repo",
        "hello",
        "hello",
        TIMEOUT,
    )
    .await
    .unwrap_err();

    assert!(error.to_string().contains("claude is not signed in"));
}
```

- [ ] **Step 2: Run the focused Rust test and verify RED**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi remote::tests::launches_claude_stream_session_with_explicit_host_root
```

Expected: compilation fails because `remote::launch` does not exist.

- [ ] **Step 3: Implement the minimal launch transport**

Add this function above `sessions` in `rust/ffi/src/remote.rs`:

```rust
/// Launch a long-lived Claude stream session on the paired daemon.
pub(crate) async fn launch(
    host: &str,
    port: u16,
    project_root: &str,
    prompt: &str,
    title: &str,
    timeout: Duration,
) -> Result<RemoteSession, PocketError> {
    let payload = serde_json::json!({
        "projectRoot": project_root,
        "cwd": project_root,
        "harness": "claude",
        "prompt": prompt,
        "title": title,
        "launchMode": "stream",
    })
    .to_string();
    let body = request(
        host,
        port,
        "POST",
        "/api/v1/sessions",
        Some(&payload),
        timeout,
    )
    .await?;
    let row: serde_json::Value =
        serde_json::from_str(&body).map_err(|error| daemon_shape_error("launched session", error))?;
    Ok(session_from(&row))
}
```

Expose it from the `PocketEngine` UniFFI impl in `rust/ffi/src/lib.rs`:

```rust
/// Launch Claude through the paired daemon's host-side CLI login.
#[allow(clippy::too_many_arguments)]
pub async fn remote_launch_session(
    &self,
    host: String,
    port: u16,
    project_root: String,
    prompt: String,
    title: String,
    timeout_ms: u32,
) -> Result<RemoteSession, PocketError> {
    remote::launch(
        &host,
        port,
        &project_root,
        &prompt,
        &title,
        millis(timeout_ms),
    )
    .await
}
```

- [ ] **Step 4: Run all remote Rust tests and verify GREEN**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi remote::tests
```

Expected: all remote transport tests pass, including the two launch tests.

- [ ] **Step 5: Run Rust formatting and lint**

Run:

```bash
cd rust
cargo fmt --all --check
cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings
```

Expected: both commands exit zero.

- [ ] **Step 6: Prepare the checkpoint commit only after explicit commit authority**

```bash
git add rust/ffi/src/remote.rs rust/ffi/src/lib.rs
git commit -m "feat(companion): launch Claude daemon sessions"
```

Do not run this step under the current conservative profile without Val's explicit commit authorization.

### Task 2: Chat backend and transcript semantics

**Files:**
- Modify: `app/Sources/Support/ChatTypes.swift`
- Modify: `app/Sources/Support/ChatModel.swift`
- Modify: `app/Sources/Support/RemoteTranscript.swift`
- Modify: `app/Tests/ChatSurfaceTests.swift`
- Modify: `app/Tests/RemoteAttachTests.swift`

- [ ] **Step 1: Add failing backend and stream-result tests**

Add to `ChatSurfaceTests`:

```swift
func testChatSettingsDefaultToCompanionWithoutAnAPIKey() {
    let settings = ChatSettings()
    XCTAssertEqual(settings.backend, .companionClaude)
    XCTAssertEqual(settings.model, "")
    XCTAssertEqual(settings.daemonProjectRoot, "")
}
```

Add to `RemoteAttachTests`:

```swift
func testStreamResultMeansTurnCompleteWithoutChangingOneShotCopy() {
    let events = [
        event(
            seq: 1,
            kind: "result",
            payload: #"{"type":"result","subtype":"success","is_error":false}"#
        )
    ]

    XCTAssertEqual(RemoteTranscript.items(from: events)[0].text, "Session finished")
    XCTAssertEqual(
        RemoteTranscript.items(from: events, resultSemantics: .turn)[0].text,
        "Turn complete"
    )
}
```

- [ ] **Step 2: Run the focused Swift tests and verify RED**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,id=8E08D33E-D46E-40D6-921C-6B8475046CFC' \
  -only-testing:CovenPocketTests/ChatSurfaceTests/testChatSettingsDefaultToCompanionWithoutAnAPIKey \
  -only-testing:CovenPocketTests/RemoteAttachTests/testStreamResultMeansTurnCompleteWithoutChangingOneShotCopy \
  test
```

Expected: compilation fails because `ChatBackend`, the new settings fields, and `resultSemantics` do not exist.

- [ ] **Step 3: Replace Chat's provider settings with an app-level backend**

Replace `ChatSettings` in `app/Sources/Support/ChatTypes.swift` with:

```swift
enum ChatBackend: String, CaseIterable, Hashable {
    case companionClaude
    case codex

    var label: String {
        switch self {
        case .companionClaude: return "Claude via Companion"
        case .codex: return "Codex"
        }
    }
}

/// Backend-specific settings for the Chat surface.
struct ChatSettings: Equatable {
    var backend: ChatBackend = .companionClaude
    var model: String = ""
    var daemonProjectRoot: String = ""
}
```

In `ChatModel.activeSession` and `ChatModel.resume`, hard-code the remaining
local path to Codex:

```swift
provider: .codex,
apiKey: "",
model: settings.model,
effort: nil,
```

Keep `ChatModel`'s existing workspace, memory, permission, session-browser,
and approval behavior unchanged.

- [ ] **Step 4: Add explicit result semantics**

Add to `RemoteTranscript`:

```swift
enum ResultSemantics: Equatable {
    case session
    case turn
}
```

Change the entry point to:

```swift
static func items(
    from events: [RemoteEvent],
    resultSemantics: ResultSemantics = .session
) -> [RemoteTranscriptItem]
```

Pass `resultSemantics` into `appendStatus`. In the `result` arm use:

```swift
let successText = resultSemantics == .turn ? "Turn complete" : "Session finished"
let errorText = resultSemantics == .turn
    ? "Turn finished with an error"
    : "Session finished with an error"
append(
    &items,
    id: id,
    role: .status,
    text: isError ? errorText : successText
)
```

- [ ] **Step 5: Run the focused Swift tests and verify GREEN**

Run the same `xcodebuild` command from Step 2.

Expected: both focused tests pass.

- [ ] **Step 6: Prepare the checkpoint commit only after explicit commit authority**

```bash
git add app/Sources/Support/ChatTypes.swift \
  app/Sources/Support/ChatModel.swift \
  app/Sources/Support/RemoteTranscript.swift \
  app/Tests/ChatSurfaceTests.swift \
  app/Tests/RemoteAttachTests.swift
git commit -m "refactor(chat): define daemon-backed Claude backend"
```

Do not run this step under the current conservative profile without Val's explicit commit authorization.

### Task 3: Companion chat state model

**Files:**
- Create: `app/Sources/Support/CompanionChatModel.swift`
- Create: `app/Tests/CompanionChatTests.swift`

- [ ] **Step 1: Write the in-memory client and failing lifecycle tests**

Create `app/Tests/CompanionChatTests.swift` with:

```swift
import XCTest
@testable import CovenPocket

@MainActor
private final class FakeCompanionSessionClient: CompanionSessionClient {
    var gate: CompanionModel.SessionGate
    var launchedPrompts: [String] = []
    var sentInputs: [String] = []
    var killedSessionIDs: [String] = []
    var eventBatches: [RemoteEventBatch] = []

    init(gate: CompanionModel.SessionGate) {
        self.gate = gate
    }

    func sessionGate() async -> CompanionModel.SessionGate { gate }

    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String
    ) async throws -> RemoteSession {
        launchedPrompts.append(prompt)
        return RemoteSession(
            id: "session-1",
            harness: "claude",
            title: title,
            status: "running",
            projectRoot: projectRoot,
            createdAt: "c",
            updatedAt: "u"
        )
    }

    func events(
        pairing: DaemonPairing,
        sessionID: String,
        afterSeq: Int64
    ) async throws -> RemoteEventBatch {
        if eventBatches.isEmpty {
            return RemoteEventBatch(events: [], nextAfterSeq: afterSeq, hasMore: false)
        }
        return eventBatches.removeFirst()
    }

    func sendInput(
        pairing: DaemonPairing,
        sessionID: String,
        data: String
    ) async throws {
        sentInputs.append(data)
    }

    func kill(pairing: DaemonPairing, sessionID: String) async throws {
        killedSessionIDs.append(sessionID)
    }
}

private func pairedDaemon() -> DaemonPairing {
    DaemonPairing(
        host: "mac.tailnet.ts.net",
        port: 7777,
        apiVersion: "coven.daemon.v1",
        covenVersion: "0.7.0",
        pid: 42,
        startedAt: "now",
        pairedAt: Date()
    )
}

@MainActor
final class CompanionChatTests: XCTestCase {
    func testFirstTurnLaunchesOnceAndFollowUpUsesInput() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: " /srv/repo ")
        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.sentInputs, [])

        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.sentInputs, ["second"])
    }

    func testUnverifiedPairingBlocksWithoutLaunching() async {
        let client = FakeCompanionSessionClient(gate: .notPaired)
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "hello", projectRoot: "/srv/repo")

        XCTAssertTrue(client.launchedPrompts.isEmpty)
        XCTAssertTrue(client.sentInputs.isEmpty)
        XCTAssertFalse(model.items.isEmpty)
    }

    func testEventsAdvanceCursorAndRenderTurnCompletion() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 7,
                        kind: "assistant",
                        payloadJson: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#,
                        createdAt: "t"
                    ),
                    RemoteEvent(
                        seq: 8,
                        kind: "result",
                        payloadJson: #"{"type":"result","is_error":false}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 8,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertEqual(model.cursor, 8)
        XCTAssertEqual(model.items.map(\.text), ["Done", "Turn complete"])
        XCTAssertFalse(model.isBusy)
    }

    func testApprovalsAndStopUseDaemonInputAndKill() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")

        await model.approve()
        await model.deny()
        await model.stop()

        XCTAssertEqual(client.sentInputs, ["y\n", "n\n"])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }
}
```

- [ ] **Step 2: Run the new test file and verify RED**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,id=8E08D33E-D46E-40D6-921C-6B8475046CFC' \
  -only-testing:CovenPocketTests/CompanionChatTests test
```

Expected: compilation fails because `CompanionSessionClient` and
`CompanionChatModel` do not exist.

- [ ] **Step 3: Implement the protocol and production adapter**

Create `app/Sources/Support/CompanionChatModel.swift`. Define:

```swift
import Foundation

@MainActor
protocol CompanionSessionClient: AnyObject {
    func sessionGate() async -> CompanionModel.SessionGate
    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String
    ) async throws -> RemoteSession
    func events(
        pairing: DaemonPairing,
        sessionID: String,
        afterSeq: Int64
    ) async throws -> RemoteEventBatch
    func sendInput(
        pairing: DaemonPairing,
        sessionID: String,
        data: String
    ) async throws
    func kill(pairing: DaemonPairing, sessionID: String) async throws
}

@MainActor
final class LiveCompanionSessionClient: CompanionSessionClient {
    let companion: CompanionModel

    init(companion: CompanionModel) {
        self.companion = companion
    }

    func sessionGate() async -> CompanionModel.SessionGate {
        await companion.gateForSessionTraffic()
    }

    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String
    ) async throws -> RemoteSession {
        try await companion.engine.remoteLaunchSession(
            host: pairing.host,
            port: pairing.port,
            projectRoot: projectRoot,
            prompt: prompt,
            title: title,
            timeoutMs: CompanionChatModel.requestTimeoutMs
        )
    }

    func events(
        pairing: DaemonPairing,
        sessionID: String,
        afterSeq: Int64
    ) async throws -> RemoteEventBatch {
        try await companion.engine.remoteEvents(
            host: pairing.host,
            port: pairing.port,
            sessionId: sessionID,
            afterSeq: afterSeq,
            limit: CompanionChatModel.pageLimit,
            timeoutMs: CompanionChatModel.requestTimeoutMs
        )
    }

    func sendInput(
        pairing: DaemonPairing,
        sessionID: String,
        data: String
    ) async throws {
        try await companion.engine.remoteSendInput(
            host: pairing.host,
            port: pairing.port,
            sessionId: sessionID,
            data: data,
            timeoutMs: CompanionChatModel.requestTimeoutMs
        )
    }

    func kill(pairing: DaemonPairing, sessionID: String) async throws {
        try await companion.engine.remoteKill(
            host: pairing.host,
            port: pairing.port,
            sessionId: sessionID,
            timeoutMs: CompanionChatModel.requestTimeoutMs
        )
    }
}
```

- [ ] **Step 4: Implement the companion model**

In the same file, implement `CompanionChatModel` with these public contracts:

```swift
@MainActor
final class CompanionChatModel: ObservableObject {
    enum Availability: Equatable {
        case checking
        case ready(DaemonPairing)
        case blocked(reason: String, hint: String)
    }

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var canRetry = false
    @Published private(set) var approvalPrompt: String?
    @Published private(set) var availability: Availability = .checking

    private(set) var cursor: Int64 = 0

    static let requestTimeoutMs: UInt32 = 6_000
    static let pageLimit: UInt32 = 200
    static let pollInterval: Duration = .seconds(2)

    let companion: CompanionModel
    private let client: any CompanionSessionClient
    private var pairing: DaemonPairing?
    private var session: RemoteSession?
    private var accumulatedEvents: [RemoteEvent] = []
    private var retryPrompt: String?
    private var retryProjectRoot = ""
    private var pollTask: Task<Void, Never>?

    convenience init(companion: CompanionModel = CompanionModel()) {
        self.init(
            companion: companion,
            client: LiveCompanionSessionClient(companion: companion)
        )
    }

    init(
        companion: CompanionModel = CompanionModel(),
        client: any CompanionSessionClient
    ) {
        self.companion = companion
        self.client = client
    }

    var isAvailable: Bool {
        if case .ready = availability { return true }
        return false
    }

    func refreshAvailability() async {
        availability = Self.availability(from: await client.sessionGate())
    }

    func send(prompt: String, projectRoot: String) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isBusy else { return }
        guard Self.isAbsoluteHostPath(trimmedRoot) else {
            fail(
                "Enter an absolute project path on the daemon host.",
                retryPrompt: nil
            )
            return
        }
        retryProjectRoot = trimmedRoot
        guard let verified = await verifiedPairing(reportFailure: true) else {
            retryPrompt = trimmedPrompt
            canRetry = true
            return
        }

        isBusy = true
        canRetry = false
        retryPrompt = nil
        do {
            if let session {
                try await client.sendInput(
                    pairing: verified,
                    sessionID: session.id,
                    data: trimmedPrompt
                )
            } else {
                session = try await client.launch(
                    pairing: verified,
                    projectRoot: trimmedRoot,
                    prompt: trimmedPrompt,
                    title: Self.title(from: trimmedPrompt)
                )
            }
            pairing = verified
            startPolling()
        } catch {
            isBusy = false
            fail(error.localizedDescription, retryPrompt: trimmedPrompt)
        }
    }

    func retry() async {
        guard let prompt = retryPrompt, !isBusy else { return }
        retryPrompt = nil
        await send(prompt: prompt, projectRoot: retryProjectRoot)
    }

    func refreshOnce() async {
        guard let pairing, let session else { return }
        do {
            var hasMore = true
            while hasMore && !Task.isCancelled {
                let page = try await client.events(
                    pairing: pairing,
                    sessionID: session.id,
                    afterSeq: cursor
                )
                let knownSequences = Set(accumulatedEvents.map(\.seq))
                accumulatedEvents.append(
                    contentsOf: page.events.filter { !knownSequences.contains($0.seq) }
                )
                cursor = max(cursor, page.nextAfterSeq)
                hasMore = page.hasMore
            }
            apply(events: accumulatedEvents)
        } catch {
            items.append(ChatItem(kind: .error, text: error.localizedDescription))
            if error.localizedDescription.localizedCaseInsensitiveContains(
                "session is not live"
            ) {
                pollTask?.cancel()
                pollTask = nil
                session = nil
                isBusy = false
            }
        }
    }

    func apply(events: [RemoteEvent]) {
        accumulatedEvents = events
        cursor = max(cursor, events.map(\.seq).max() ?? cursor)
        let remoteItems = RemoteTranscript.items(
            from: events,
            resultSemantics: .turn
        )
        items = Self.chatItems(from: remoteItems)
        approvalPrompt = RemoteTranscript.approvalPrompt(in: remoteItems)

        if let newestResult = events
            .filter({ $0.kind == "result" })
            .map(\.seq)
            .max(),
           newestResult > lastCompletedResultSeq {
            lastCompletedResultSeq = newestResult
            isBusy = false
        }
    }

    func approve() async {
        await sendControl("y\n")
    }

    func deny() async {
        await sendControl("n\n")
    }

    func stop() async {
        guard let session, let verified = await verifiedPairing(reportFailure: true) else {
            return
        }
        do {
            try await client.kill(pairing: verified, sessionID: session.id)
            pollTask?.cancel()
            pollTask = nil
            self.session = nil
            isBusy = false
            items.append(ChatItem(kind: .status, text: "Stopped."))
        } catch {
            items.append(ChatItem(kind: .error, text: error.localizedDescription))
        }
    }

    func reset() async {
        if let session,
           let verified = await verifiedPairing(reportFailure: false) {
            try? await client.kill(pairing: verified, sessionID: session.id)
        }
        pollTask?.cancel()
        pollTask = nil
        pairing = nil
        session = nil
        accumulatedEvents = []
        cursor = 0
        lastCompletedResultSeq = 0
        retryPrompt = nil
        retryProjectRoot = ""
        items = []
        approvalPrompt = nil
        isBusy = false
        canRetry = false
    }
}
```

Add this stored property beside `pollTask`:

```swift
private var lastCompletedResultSeq: Int64 = 0
```

Add these helpers inside `CompanionChatModel`:

```swift
private static func availability(
    from gate: CompanionModel.SessionGate
) -> Availability {
    switch gate {
    case let .ready(pairing):
        return .ready(pairing)
    case .notPaired:
        return .blocked(
            reason: "Not paired",
            hint: "Pair with a daemon in the Companion tab first."
        )
    case let .blocked(reason, hint):
        return .blocked(reason: reason, hint: hint)
    }
}

private func verifiedPairing(reportFailure: Bool) async -> DaemonPairing? {
    let gate = await client.sessionGate()
    availability = Self.availability(from: gate)
    switch gate {
    case let .ready(pairing):
        return pairing
    case .notPaired:
        if reportFailure {
            fail(
                "Not paired. Pair with a daemon in the Companion tab first.",
                retryPrompt: nil
            )
        }
    case let .blocked(reason, hint):
        if reportFailure {
            fail("\(reason). \(hint)", retryPrompt: nil)
        }
    }
    return nil
}

private func sendControl(_ data: String) async {
    guard let session,
          let verified = await verifiedPairing(reportFailure: true) else {
        return
    }
    do {
        try await client.sendInput(
            pairing: verified,
            sessionID: session.id,
            data: data
        )
        approvalPrompt = nil
    } catch {
        items.append(ChatItem(kind: .error, text: error.localizedDescription))
    }
}

private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
        while !Task.isCancelled {
            await self?.refreshOnce()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

private func fail(_ message: String, retryPrompt: String?) {
    items.append(ChatItem(kind: .error, text: message))
    self.retryPrompt = retryPrompt
    canRetry = retryPrompt != nil
}

private static func isAbsoluteHostPath(_ path: String) -> Bool {
    path.hasPrefix("/")
        || path.range(
            of: #"^[A-Za-z]:[\\/]"#,
            options: .regularExpression
        ) != nil
}

private static func title(from prompt: String) -> String {
    let firstLine = prompt.split(separator: "\n", maxSplits: 1).first.map(String.init)
        ?? "Claude session"
    return String(firstLine.prefix(80))
}
```

The implementation must not invoke `PocketProvider.anthropic`, `listModels`,
or `startChat`.

Use this mapping helper:

```swift
private static func chatItems(from remote: [RemoteTranscriptItem]) -> [ChatItem] {
    remote.map { item in
        switch item.role {
        case .user:
            return ChatItem(kind: .user, text: item.text)
        case .assistant:
            return ChatItem(kind: .assistant, text: item.text)
        case .terminal:
            return ChatItem(kind: .status, text: item.text)
        case .status:
            return ChatItem(kind: .status, text: item.text)
        case let .tool(isError):
            return ChatItem(
                kind: .tool,
                text: "Tool result",
                tool: ToolCallInfo(
                    toolId: "remote-\(item.id)",
                    name: "Tool result",
                    inputSummary: "",
                    result: item.text,
                    isError: isError,
                    isRunning: false
                )
            )
        }
    }
}
```

- [ ] **Step 5: Run the companion tests and verify GREEN**

Run the same `xcodebuild` command from Step 2.

Expected: all `CompanionChatTests` pass.

- [ ] **Step 6: Run SwiftLint on the new model and tests**

```bash
swiftlint lint --strict \
  app/Sources/Support/CompanionChatModel.swift \
  app/Tests/CompanionChatTests.swift
```

Expected: zero warnings and zero errors.

- [ ] **Step 7: Prepare the checkpoint commit only after explicit commit authority**

```bash
git add app/Sources/Support/CompanionChatModel.swift app/Tests/CompanionChatTests.swift
git commit -m "feat(chat): add companion Claude session model"
```

Do not run this step under the current conservative profile without Val's explicit commit authorization.

### Task 4: Route the Chat UI through the selected backend

**Files:**
- Modify: `app/Sources/Views/ChatSettingsView.swift`
- Modify: `app/Sources/Views/ChatView.swift`
- Modify: `app/Sources/Views/RemoteSessionsView.swift`
- Modify: `app/Tests/ChatSurfaceTests.swift`

- [ ] **Step 1: Add a failing source contract test**

Add to `ChatSurfaceTests`:

```swift
func testChatSurfaceHasNoAnthropicAPIKeyUIOrKeychainRead() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let files = [
        "Sources/Support/ChatTypes.swift",
        "Sources/Views/ChatView.swift",
        "Sources/Views/ChatSettingsView.swift"
    ]
    let source = try files
        .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")

    XCTAssertFalse(source.contains("anthropic-api-key"))
    XCTAssertFalse(source.contains("Anthropic API key"))
    XCTAssertFalse(source.contains("settings.apiKey"))
    XCTAssertTrue(source.contains("Claude via Companion"))
}
```

- [ ] **Step 2: Run the source contract test and verify RED**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,id=8E08D33E-D46E-40D6-921C-6B8475046CFC' \
  -only-testing:CovenPocketTests/ChatSurfaceTests/testChatSurfaceHasNoAnthropicAPIKeyUIOrKeychainRead \
  test
```

Expected: the test fails because Chat still contains the Anthropic key field and Keychain read.

- [ ] **Step 3: Replace provider settings with backend-specific sections**

Change `ChatSettingsView` to accept:

```swift
@Binding var settings: ChatSettings
@ObservedObject var client: EngineClient
@ObservedObject var model: ChatModel
@ObservedObject var companionModel: CompanionChatModel
```

The Provider picker must contain:

```swift
Picker("Backend", selection: $settings.backend) {
    if companionModel.isAvailable || settings.backend == .companionClaude {
        Text(ChatBackend.companionClaude.label).tag(ChatBackend.companionClaude)
    }
    if client.codexAccount != nil || settings.backend == .codex {
        Text(ChatBackend.codex.label).tag(ChatBackend.codex)
    }
}
```

For `.companionClaude`, render:

```swift
TextField("Project path on daemon host", text: $settings.daemonProjectRoot)
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .onChange(of: settings.daemonProjectRoot) { _, value in
        UserDefaults.standard.set(value, forKey: "daemon-chat-project-root")
    }

Button("Verify daemon") {
    Task { await companionModel.refreshAvailability() }
}
```

Show the exact `Availability.blocked` reason and hint. Include an “Open
Companion” button that sets `AppRouter.shared.selectedTab = .companion` and
dismisses the sheet.

For `.codex`, retain account and model selection. Show local memory,
permission, and clear-conversation controls only in the Codex branch.
Remove the Anthropic key field, Anthropic model loader, and effort picker.

- [ ] **Step 4: Route ChatView actions and rendering**

Add:

```swift
@StateObject private var companionModel = CompanionChatModel()

@State private var settings = ChatSettings(
    daemonProjectRoot: UserDefaults.standard.string(
        forKey: "daemon-chat-project-root"
    ) ?? ""
)
```

Derive active state:

```swift
private var activeItems: [ChatItem] {
    settings.backend == .companionClaude ? companionModel.items : model.items
}

private var activeIsBusy: Bool {
    settings.backend == .companionClaude ? companionModel.isBusy : model.isBusy
}

private var activeCanRetry: Bool {
    settings.backend == .companionClaude ? companionModel.canRetry : model.canRetry
}
```

`canSend` must require:

- a non-empty prompt;
- a freshly ready companion and absolute-looking daemon root for companion
  Claude; or
- a Codex account and model for local Codex.

Route Send, Retry, Stop, Reset, share items, empty-state copy, and settings to
the active model. For companion Stop and Reset, wrap the async methods in a
`Task`.

When companion approval copy is non-nil, insert a bar above the input with
Approve and Deny buttons calling `companionModel.approve()` and
`companionModel.deny()`.

Keep the local `ApprovalSheet` and permission toolbar only for Codex.

On appearance call:

```swift
.task {
    await companionModel.refreshAvailability()
    if settings.model.isEmpty {
        settings.model = client.defaultCodexModel
    }
}
```

For history:

- companion backend presents `RemoteSessionsView` with
  `companionModel.companion`;
- Codex backend presents `SessionsView`.

For a Spotlight local-session handoff, explicitly set
`settings.backend = .codex` before resuming. This is user-selected history,
not an error fallback.

- [ ] **Step 5: Make remote session history sheet-safe**

Add an optional Done toolbar to `RemoteSessionsView`, controlled by an
initializer flag:

```swift
private let showsDoneButton: Bool

init(companion: CompanionModel, showsDoneButton: Bool = false) {
    self.showsDoneButton = showsDoneButton
    _model = StateObject(wrappedValue: RemoteSessionsModel(companion: companion))
}
```

When presented from Chat, wrap it in `NavigationStack` and pass
`showsDoneButton: true`; use `@Environment(\.dismiss)` for the Done action.
The existing push from `CompanionView` keeps the default `false`.

- [ ] **Step 6: Run the source contract and companion tests**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,id=8E08D33E-D46E-40D6-921C-6B8475046CFC' \
  -only-testing:CovenPocketTests/ChatSurfaceTests \
  -only-testing:CovenPocketTests/CompanionChatTests \
  test
```

Expected: both test classes pass.

- [ ] **Step 7: Run SwiftLint**

```bash
swiftlint lint --strict
```

Expected: zero warnings and zero errors.

- [ ] **Step 8: Prepare the checkpoint commit only after explicit commit authority**

```bash
git add app/Sources/Views/ChatSettingsView.swift \
  app/Sources/Views/ChatView.swift \
  app/Sources/Views/RemoteSessionsView.swift \
  app/Tests/ChatSurfaceTests.swift
git commit -m "feat(chat): route Claude through paired daemon"
```

Do not run this step under the current conservative profile without Val's explicit commit authorization.

### Task 5: Preserve explicit platform boundaries

**Files:**
- Modify: `app/Sources/Intents/CovenIntents.swift`
- Modify: `ROADMAP.md`

- [ ] **Step 1: Update intent copy without changing its routing contract**

Change `AskCovenIntent.description` to:

```swift
static let description = IntentDescription(
    "Send a prompt to the coding agent. Optional iOS workspaces apply to on-device Codex."
)
```

Keep `IntentActions.ask` unchanged. A selected iOS workspace remains useful
for Codex and is ignored by companion Claude, which requires its own explicit
host path.

- [ ] **Step 2: Run App Intents regression tests**

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,id=8E08D33E-D46E-40D6-921C-6B8475046CFC' \
  -only-testing:CovenPocketTests/AppIntentsTests test
```

Expected: all App Intents tests pass.

- [ ] **Step 3: Mark the roadmap item complete only after functional tests pass**

In `ROADMAP.md`, change the M2 item marker:

```markdown
- [x] Anthropic subscription access via the companion's `claude` CLI login:
```

Keep the existing credential-boundary explanation beneath it.

- [ ] **Step 4: Prepare the checkpoint commit only after explicit commit authority**

```bash
git add app/Sources/Intents/CovenIntents.swift ROADMAP.md
git commit -m "docs(companion): mark daemon Claude chat complete"
```

Do not run this step under the current conservative profile without Val's explicit commit authorization.

### Task 6: Full verification and Beads completion

**Files:**
- Verify all changed files
- Update Bead: `pocket-d3u`

- [ ] **Step 1: Regenerate the XCFramework and bindings**

```bash
./scripts/build-xcframework.sh
```

Expected: all required iOS slices and generated Swift bindings complete
successfully. Do not edit generated Swift by hand.

- [ ] **Step 2: Run the complete Rust quality gates**

```bash
cd rust
cargo test -p coven-pocket-ffi
cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings
cargo fmt --all --check
cd ..
```

Expected: all tests pass and lint/format exit zero.

- [ ] **Step 3: Regenerate the disposable Xcode project and run all Swift tests**

```bash
xcodegen generate
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,id=8E08D33E-D46E-40D6-921C-6B8475046CFC' \
  test
```

Expected: `CovenPocketTests` passes completely. Do not add
`CovenPocket.xcodeproj` to git.

- [ ] **Step 4: Run the app build and SwiftLint**

```bash
swiftlint lint --strict
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: SwiftLint is clean and the simulator build succeeds.

- [ ] **Step 5: Audit the provider boundary and diff**

```bash
rg -n "anthropic-api-key|Anthropic API key|settings\\.apiKey" \
  app/Sources/Views/ChatView.swift \
  app/Sources/Views/ChatSettingsView.swift \
  app/Sources/Support/ChatTypes.swift
rg -n "remoteLaunchSession|launchMode.*stream|Claude via Companion" \
  app rust/ffi/src
git diff --check
git status --short --branch
```

Expected:

- the first search returns no matches;
- the second search identifies the Rust launch, Swift client, and UI backend;
- `git diff --check` exits zero; and
- only intended source, test, documentation, and Beads files are changed.

- [ ] **Step 6: Close the Bead only after every completion criterion is proved**

```bash
bd close pocket-d3u --reason="Daemon-backed Claude Chat implemented and fully verified"
bd show pocket-d3u
git status --short --branch
```

Expected: `pocket-d3u` is closed and the final status remains ready for
conservative handoff.

- [ ] **Step 7: Commit or push only with explicit authority**

Under the current conservative profile, report the verified diff and proposed
commit command instead of committing or pushing. If Val explicitly authorizes a
commit, use a squashable subject such as:

```bash
git add .beads/issues.jsonl ROADMAP.md app rust docs/superpowers
git commit -m "feat(chat): route Claude through the paired daemon"
```

Do not push or open a PR unless separately requested.
