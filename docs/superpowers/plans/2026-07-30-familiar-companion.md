# Familiar Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add roster-driven familiar selection to on-device Codex and paired-daemon Claude sessions without restoring the obsolete built-in roster or widening permissions.

**Architecture:** Extend the bounded daemon client with a typed familiar roster and optional launch identity, persist on-device session identity in a small sidecar owned by the Pocket FFI, and keep profile-scoped selection in a dedicated main-actor Swift model. Companion launches send only the selected familiar ID to the daemon; on-device sessions consume a validated display-name/role snapshot and pin it across resume/fork.

**Tech Stack:** Rust, UniFFI, Tokio, serde/serde_json, Swift 5.10, SwiftUI, XCTest, UserDefaults

---

## File Structure

**Create**

- `app/Sources/Support/FamiliarSelectionModel.swift` — profile keys, Codable preference document, roster refresh generation, selected snapshot.
- `app/Sources/Views/FamiliarPickerSection.swift` — focused SwiftUI picker/status surface.
- `app/Tests/FamiliarSelectionTests.swift` — persistence, profile isolation, stale refresh, removed-familiar behavior.

**Modify**

- `rust/ffi/src/remote.rs` — `RemoteFamiliar`, roster endpoint, optional familiar launch field.
- `rust/ffi/src/lib.rs` — UniFFI exports and updated chat/session method signatures.
- `rust/ffi/src/chat.rs` — typed familiar snapshot and identity preamble in the on-device system prompt.
- `rust/ffi/src/sessions.rs` — per-session familiar sidecar, list/resume/fork/delete preservation.
- `app/Sources/Support/ChatTypes.swift` — selected familiar ID in `ChatSettings`.
- `app/Sources/Support/ChatModel.swift` — resolve selected snapshot, pass it into start/resume, preserve session settings.
- `app/Sources/Support/CompanionSessionClient.swift` — optional familiar ID in launch contract.
- `app/Sources/Support/CompanionChatModel.swift` — selected/retry/session familiar state.
- `app/Sources/Support/CompanionChatModel+Session.swift` — familiar-aware reuse and launch.
- `app/Sources/Support/CompanionChatModel+Cleanup.swift` — clear familiar binding with session cleanup.
- `app/Sources/Views/ChatView.swift` — shared model construction, send/retry routing, active familiar indicator.
- `app/Sources/Views/ChatSettingsView.swift` — embed familiar picker.
- `app/Tests/CompanionChatTestSupport.swift` — capture familiar launch arguments.
- `app/Tests/CompanionChatLifecycleTests.swift` — familiar change retires the old daemon session.
- `app/Tests/ChatSurfaceTests.swift` — on-device identity preamble and persisted session identity.
- `ROADMAP.md` — mark the upstream-aligned familiar companion complete.

**Generated**

- `app/Sources/Generated/coven_pocket_ffi.swift` — regenerate only through `./scripts/build-xcframework.sh`.
- `build/CovenPocketCore.xcframework` — local build artifact, not committed.

## Task 1: Typed Daemon Familiar Contract

**Files:**
- Modify: `rust/ffi/src/remote.rs`
- Modify: `rust/ffi/src/lib.rs`
- Test: `rust/ffi/src/remote.rs`

- [ ] **Step 1: Write failing roster and launch-contract tests**

Add these tests beside the existing `remote.rs` tests:

```rust
#[tokio::test]
async fn lists_familiars_with_safe_defaults() {
    let (port, rx) = serve_once(
        "HTTP/1.1 200 OK",
        r#"[{"id":"sage","display_name":"Sage","emoji":"owl","role":"Guide",
            "description":"Explains tradeoffs.","pronouns":"they/them",
            "icon":"ph:owl-fill"},
           {"id":"forge"}]"#,
    )
    .await;

    let rows = familiars("127.0.0.1", port, TIMEOUT).await.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].id, "sage");
    assert_eq!(rows[0].display_name, "Sage");
    assert_eq!(rows[0].role.as_deref(), Some("Guide"));
    assert_eq!(rows[1].display_name, "forge");
    assert!(rx.await.unwrap().starts_with("GET /api/v1/familiars HTTP/1.1"));
}

#[tokio::test]
async fn familiar_list_rejects_blank_and_duplicate_ids() {
    let (port, _) = serve_once(
        "HTTP/1.1 200 OK",
        r#"[{"id":"sage"},{"id":" "},{"id":"SAGE"}]"#,
    )
    .await;

    let error = familiars("127.0.0.1", port, TIMEOUT).await.unwrap_err();
    assert!(error.to_string().contains("familiar roster"));
}

#[tokio::test]
async fn launch_serializes_optional_familiar_id() {
    let (port, rx) = serve_once(
        "HTTP/1.1 201 Created",
        r#"{"id":"s-1","project_root":"/srv/repo","harness":"claude",
            "title":"Fix tests","status":"running","familiar_id":"sage",
            "created_at":"c","updated_at":"u"}"#,
    )
    .await;

    let session = launch(
        "127.0.0.1",
        port,
        "/srv/repo",
        "Fix tests",
        "Fix tests",
        Some("sage"),
        TIMEOUT,
    )
    .await
    .unwrap();

    assert_eq!(session.familiar_id.as_deref(), Some("sage"));
    let request = rx.await.unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(payload["familiarId"], "sage");
}

#[tokio::test]
async fn launch_omits_familiar_id_when_none() {
    let (port, rx) = serve_once(
        "HTTP/1.1 201 Created",
        r#"{"id":"s-1","project_root":"/srv/repo","harness":"claude",
            "title":"Fix tests","status":"running",
            "created_at":"c","updated_at":"u"}"#,
    )
    .await;

    launch(
        "127.0.0.1",
        port,
        "/srv/repo",
        "Fix tests",
        "Fix tests",
        None,
        TIMEOUT,
    )
    .await
    .unwrap();

    let request = rx.await.unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert!(payload.get("familiarId").is_none());
}
```

Update existing launch calls in tests to pass `None`.

- [ ] **Step 2: Run the Rust tests and confirm the contract is missing**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi remote::tests::lists_familiars_with_safe_defaults
```

Expected: compile failure because `familiars`, familiar fields, and the new launch argument do not exist.

- [ ] **Step 3: Implement the typed roster and optional launch field**

Add these records and helpers in `remote.rs`:

```rust
#[derive(uniffi::Record, Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct FamiliarIdentity {
    pub id: String,
    pub display_name: String,
    pub emoji: Option<String>,
    pub role: Option<String>,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct RemoteFamiliar {
    pub id: String,
    pub display_name: String,
    pub emoji: Option<String>,
    pub role: Option<String>,
    pub description: Option<String>,
    pub pronouns: Option<String>,
    pub icon: Option<String>,
}
```

Change `RemoteSession` to include:

```rust
pub familiar_id: Option<String>,
```

Change `launch` to accept `familiar_id: Option<&str>`, build the existing
payload as a mutable `serde_json::Value`, and insert only nonblank IDs:

```rust
let mut payload = serde_json::json!({
    "projectRoot": project_root,
    "cwd": project_root,
    "harness": "claude",
    "prompt": prompt,
    "title": title,
    "launchMode": "stream",
});
if let Some(familiar_id) = familiar_id.map(str::trim).filter(|id| !id.is_empty()) {
    payload["familiarId"] = serde_json::Value::String(familiar_id.to_string());
}
let payload = payload.to_string();
```

Add:

```rust
pub(crate) async fn familiars(
    host: &str,
    port: u16,
    timeout: Duration,
) -> Result<Vec<RemoteFamiliar>, PocketError> {
    let body = request(host, port, "GET", "/api/v1/familiars", None, timeout).await?;
    let rows: Vec<serde_json::Value> = serde_json::from_str(&body)
        .map_err(|error| daemon_shape_error("familiar roster", error))?;
    let mut seen = std::collections::HashSet::new();
    rows.into_iter()
        .map(|row| {
            let id = row.get("id").and_then(|value| value.as_str())
                .unwrap_or_default().trim().to_string();
            let key = id.to_ascii_lowercase();
            if id.is_empty() || !seen.insert(key) {
                return Err(PocketError::Engine {
                    message: "could not read the daemon's familiar roster: blank or duplicate id"
                        .to_string(),
                });
            }
            let optional = |key: &str| {
                row.get(key).and_then(|value| value.as_str())
                    .map(str::trim).filter(|value| !value.is_empty()).map(str::to_string)
            };
            Ok(RemoteFamiliar {
                display_name: optional("display_name").unwrap_or_else(|| id.clone()),
                id,
                emoji: optional("emoji"),
                role: optional("role"),
                description: optional("description"),
                pronouns: optional("pronouns"),
                icon: optional("icon"),
            })
        })
        .collect()
}
```

Populate `RemoteSession.familiar_id` from `familiar_id`, and export
`PocketEngine::remote_familiars` plus the updated optional `familiar_id`
argument on `remote_launch_session` in `lib.rs`.

- [ ] **Step 4: Run the complete remote Rust tests**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi remote::tests
```

Expected: all remote tests pass.

- [ ] **Step 5: Commit**

```bash
git add rust/ffi/src/remote.rs rust/ffi/src/lib.rs
git commit -m "feat(familiar): expose daemon roster" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Task 2: Pin Familiar Identity in On-Device Sessions

**Files:**
- Modify: `rust/ffi/src/chat.rs`
- Modify: `rust/ffi/src/sessions.rs`
- Modify: `rust/ffi/src/lib.rs`
- Test: `rust/ffi/src/chat.rs`
- Test: `rust/ffi/src/sessions.rs`

- [ ] **Step 1: Write failing identity and sidecar tests**

In `chat.rs`, add:

```rust
#[test]
fn familiar_identity_is_appended_without_changing_permissions() {
    let guard = crate::memory::tests::setup("chat-familiar");
    let session = start_session(
        PocketProvider::Anthropic,
        "test".into(),
        "model".into(),
        None,
        guard.workspace.display().to_string(),
        ChatPermissionMode::Plan,
        None,
        false,
        Some(crate::remote::FamiliarIdentity {
            id: "sage".into(),
            display_name: "Sage".into(),
            emoji: None,
            role: Some("Guide".into()),
        }),
    )
    .unwrap();

    let prompt = session.append_system_prompt();
    assert!(prompt.contains(
        "[Identity: You are Sage, a Guide. Respond as Sage, not as the underlying tool.]"
    ));
    assert_eq!(session.permission_mode(), ChatPermissionMode::Plan);
}

#[test]
fn familiar_identity_without_role_uses_canonical_short_form() {
    let familiar = crate::remote::FamiliarIdentity {
        id: "sage".into(),
        display_name: "Sage".into(),
        emoji: None,
        role: None,
    };

    assert_eq!(
        familiar_preamble(&familiar),
        "[Identity: You are Sage. Respond as Sage, not as the underlying tool.]"
    );
}
```

In `sessions.rs`, add:

```rust
#[tokio::test]
async fn familiar_metadata_survives_fork_and_delete() {
    let dir = std::env::temp_dir().join(format!("pocket-familiar-{}", uuid::Uuid::new_v4()));
    let storage = dir.display().to_string();
    let source = uuid::Uuid::new_v4().to_string();
    let familiar = crate::remote::FamiliarIdentity {
        id: "sage".into(),
        display_name: "Sage".into(),
        emoji: None,
        role: Some("Guide".into()),
    };
    let persistence =
        SessionPersistence::create(&storage, source.clone(), "model".into()).unwrap();
    persistence
        .persist_new(&[Message::user("hello")])
        .await
        .unwrap();
    save_familiar_metadata(&storage, &source, Some(&familiar)).unwrap();

    let fork = fork_session(&storage, &source).await.unwrap();
    assert_eq!(
        load_familiar_metadata(&storage, &fork).unwrap(),
        Some(familiar)
    );
    delete_session(&storage, &fork).unwrap();
    assert_eq!(load_familiar_metadata(&storage, &fork).unwrap(), None);
    let _ = std::fs::remove_dir_all(dir);
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi familiar_
```

Expected: compile failures for the new familiar argument and metadata helpers.

- [ ] **Step 3: Add the familiar identity preamble**

Add `familiar: Option<FamiliarIdentity>` to `SessionConfig`. Add:

```rust
fn familiar_preamble(familiar: &FamiliarIdentity) -> String {
    match familiar.role.as_deref().map(str::trim).filter(|role| !role.is_empty()) {
        Some(role) => format!(
            "[Identity: You are {name}, a {role}. Respond as {name}, not as the underlying tool.]",
            name = familiar.display_name
        ),
        None => format!(
            "[Identity: You are {name}. Respond as {name}, not as the underlying tool.]",
            name = familiar.display_name
        ),
    }
}
```

Append it after the immutable iOS platform note and before optional project
memory:

```rust
if let Some(familiar) = &self.config.familiar {
    appended.push_str("\n\n");
    appended.push_str(&familiar_preamble(familiar));
}
```

Add `familiar: Option<FamiliarIdentity>` to `start_session` and
`PocketEngine::start_chat`.

- [ ] **Step 4: Persist the identity as a per-session sidecar**

In `sessions.rs`, use
`<storage>/metadata/<session-id>.familiar.json`. Implement:

```rust
fn familiar_metadata_file(root: &Path, session_id: &str) -> PathBuf {
    root.join("metadata").join(format!("{session_id}.familiar.json"))
}

pub(crate) fn save_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
    familiar: Option<&FamiliarIdentity>,
) -> Result<(), PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let path = familiar_metadata_file(&root, session_id);
    match familiar {
        Some(familiar) => {
            std::fs::create_dir_all(root.join("metadata"))
                .map_err(|error| engine_err("cannot create session metadata dir", error))?;
            let data = serde_json::to_vec(familiar)
                .map_err(|error| engine_err("cannot encode familiar metadata", error))?;
            let temporary = path.with_extension("json.tmp");
            std::fs::write(&temporary, data)
                .map_err(|error| engine_err("cannot write familiar metadata", error))?;
            std::fs::rename(&temporary, &path)
                .map_err(|error| engine_err("cannot publish familiar metadata", error))
        }
        None => match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(engine_err("cannot delete familiar metadata", error)),
        },
    }
}

pub(crate) fn load_familiar_metadata(
    storage_dir: &str,
    session_id: &str,
) -> Result<Option<FamiliarIdentity>, PocketError> {
    validate_session_id(session_id)?;
    let root = storage_root(storage_dir)?;
    let path = familiar_metadata_file(&root, session_id);
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(engine_err("cannot read familiar metadata", error)),
    };
    serde_json::from_slice(&data)
        .map(Some)
        .map_err(|error| engine_err("cannot decode familiar metadata", error))
}
```

Add the shared fork primitive:

```rust
fn copy_familiar_metadata(
    storage_dir: &str,
    source_id: &str,
    destination_id: &str,
) -> Result<(), PocketError> {
    let familiar = load_familiar_metadata(storage_dir, source_id)?;
    save_familiar_metadata(storage_dir, destination_id, familiar.as_ref())
}
```

At new session creation, save the optional metadata before returning. At
resume, load it and ignore any current profile selection. At fork, call
`copy_familiar_metadata` after the transcript and index copy succeeds. At
delete, remove the sidecar after removing the transcript.

Extend `ChatSessionSummary` with:

```rust
pub familiar: Option<FamiliarIdentity>,
```

Populate it through `load_familiar_metadata`; a malformed sidecar must fail the
list call rather than silently changing identity.

- [ ] **Step 5: Update resume and fork semantics**

Do not add a familiar argument to `resume_chat`. `resume_session` loads the
stored snapshot:

```rust
let familiar = crate::sessions::load_familiar_metadata(&storage_dir, &session_id)?;
```

and stores it in `SessionConfig`.

Make `fork_session` call:

```rust
if let Err(error) = copy_familiar_metadata(storage_dir, session_id, &new_id) {
    if let Err(cleanup_error) = delete_session(storage_dir, &new_id) {
        return Err(engine_err(
            "cannot copy familiar metadata or roll back fork",
            format!("{error}; cleanup failed: {cleanup_error}"),
        ));
    }
    return Err(error);
}
```

after the fork transcript/index succeeds, so a metadata failure cannot leave a
visible fork with silently changed identity.

- [ ] **Step 6: Run Rust chat/session tests**

Run:

```bash
cd rust
cargo test -p coven-pocket-ffi chat::tests
cargo test -p coven-pocket-ffi sessions::tests
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add rust/ffi/src/chat.rs rust/ffi/src/sessions.rs rust/ffi/src/lib.rs
git commit -m "feat(familiar): pin on-device session identity" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Task 3: Generate Bindings and Persist Profile Selection

**Files:**
- Create: `app/Sources/Support/FamiliarSelectionModel.swift`
- Create: `app/Tests/FamiliarSelectionTests.swift`
- Generated: `app/Sources/Generated/coven_pocket_ffi.swift`

- [ ] **Step 1: Regenerate the UniFFI surface**

Run:

```bash
./scripts/build-xcframework.sh
```

Expected: framework build succeeds and generated Swift includes
`FamiliarIdentity`, `RemoteFamiliar`, `remoteFamiliars`, the updated remote
launch argument, and `ChatSessionSummary.familiar`.

- [ ] **Step 2: Write failing profile-store tests**

Create `FamiliarSelectionTests.swift`:

```swift
import XCTest
@testable import CovenPocket

@MainActor
final class FamiliarSelectionTests: XCTestCase {
    func testSelectionsAreIsolatedByProfile() throws {
        let defaults = UserDefaults(suiteName: "familiar-\(UUID().uuidString)")!
        let store = FamiliarSelectionStore(defaults: defaults)
        let sage = FamiliarIdentity(
            id: "sage", displayName: "Sage", emoji: nil, role: "Guide"
        )

        try store.save(sage, for: .codex(profileID: "account-a"))

        XCTAssertEqual(try store.load(for: .codex(profileID: "account-a")), sage)
        XCTAssertNil(try store.load(for: .codex(profileID: "account-b")))
        XCTAssertNil(try store.load(for: .companion(host: "mac", port: 7777)))
    }

    func testCorruptPreferencesReportFailure() {
        let defaults = UserDefaults(suiteName: "familiar-\(UUID().uuidString)")!
        defaults.set(Data("broken".utf8), forKey: FamiliarSelectionStore.storageKey)
        let store = FamiliarSelectionStore(defaults: defaults)

        XCTAssertThrowsError(
            try store.load(for: .codex(profileID: "account-a"))
        )
        XCTAssertNil(defaults.data(forKey: FamiliarSelectionStore.storageKey))
    }
}
```

- [ ] **Step 3: Run the focused test and verify failure**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5' \
  -only-testing:CovenPocketTests/FamiliarSelectionTests test -quiet
```

Expected: compile failure because the store and profile key do not exist.

- [ ] **Step 4: Implement the versioned preference store**

Create:

```swift
import Foundation

enum FamiliarProfileKey: Hashable {
    case codex(profileID: String)
    case companion(host: String, port: UInt16)

    var storageValue: String {
        switch self {
        case let .codex(profileID):
            return "codex:\(profileID)"
        case let .companion(host, port):
            return "companion:\(host.lowercased()):\(port)"
        }
    }
}

struct FamiliarSelectionStore {
    static let storageKey = "familiar-selections-v1"

    enum StoreError: LocalizedError {
        case corrupt

        var errorDescription: String? {
            "Saved familiar selections could not be read."
        }
    }

    private struct Snapshot: Codable {
        let id: String
        let displayName: String
        let emoji: String?
        let role: String?

        init(_ familiar: FamiliarIdentity) {
            id = familiar.id
            displayName = familiar.displayName
            emoji = familiar.emoji
            role = familiar.role
        }

        var familiar: FamiliarIdentity {
            FamiliarIdentity(
                id: id, displayName: displayName, emoji: emoji, role: role
            )
        }
    }

    private struct Document: Codable {
        var version = 1
        var selections: [String: Snapshot]
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for profile: FamiliarProfileKey) throws -> FamiliarIdentity? {
        try document().selections[profile.storageValue]?.familiar
    }

    func save(
        _ familiar: FamiliarIdentity?,
        for profile: FamiliarProfileKey
    ) throws {
        var document = try document()
        document.selections[profile.storageValue] = familiar.map(Snapshot.init)
        let data = try JSONEncoder().encode(document)
        defaults.set(data, forKey: Self.storageKey)
    }

    private func document() throws -> Document {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return Document(selections: [:])
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else {
            defaults.removeObject(forKey: Self.storageKey)
            throw StoreError.corrupt
        }
        return document
    }
}
```

- [ ] **Step 5: Run the selection-store tests**

Run the Step 3 command.

Expected: both tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/Generated/coven_pocket_ffi.swift \
  app/Sources/Support/FamiliarSelectionModel.swift \
  app/Tests/FamiliarSelectionTests.swift
git commit -m "feat(familiar): persist profile selections" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Task 4: Refresh the Canonical Roster Safely

**Files:**
- Modify: `app/Sources/Support/FamiliarSelectionModel.swift`
- Modify: `app/Tests/FamiliarSelectionTests.swift`

- [ ] **Step 1: Add a fake roster client and failing race tests**

Define the injectable boundary:

```swift
@MainActor
protocol FamiliarRosterClient: AnyObject {
    func gate() async -> CompanionModel.SessionGate
    func familiars(pairing: DaemonPairing) async throws -> [RemoteFamiliar]
}
```

Add tests proving:

```swift
enum FakeRosterError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Roster unavailable" }
}

@MainActor
final class FakeFamiliarRosterClient: FamiliarRosterClient {
    var gateResult: CompanionModel.SessionGate
    var immediateResult: Result<[RemoteFamiliar], FakeRosterError>
    var suspends = false
    let firstRequest = XCTestExpectation(description: "first roster request")
    let secondRequest = XCTestExpectation(description: "second roster request")
    private var continuations: [
        CheckedContinuation<[RemoteFamiliar], any Error>
    ] = []

    init(
        gate: CompanionModel.SessionGate,
        result: Result<[RemoteFamiliar], FakeRosterError>
    ) {
        gateResult = gate
        immediateResult = result
    }

    func gate() async -> CompanionModel.SessionGate {
        gateResult
    }

    func familiars(pairing: DaemonPairing) async throws -> [RemoteFamiliar] {
        guard suspends else { return try immediateResult.get() }
        if continuations.isEmpty {
            firstRequest.fulfill()
        } else {
            secondRequest.fulfill()
        }
        return try await withCheckedThrowingContinuation {
            continuations.append($0)
        }
    }

    func resumeFirst(with result: Result<[RemoteFamiliar], FakeRosterError>) {
        let continuation = continuations.removeFirst()
        continuation.resume(with: result.mapError { $0 as any Error })
    }

    func resumeLast(with result: Result<[RemoteFamiliar], FakeRosterError>) {
        let continuation = continuations.removeLast()
        continuation.resume(with: result.mapError { $0 as any Error })
    }
}

private func remoteFamiliar(
    id: String,
    name: String
) -> RemoteFamiliar {
    RemoteFamiliar(
        id: id,
        displayName: name,
        emoji: nil,
        role: "Guide",
        description: nil,
        pronouns: nil,
        icon: nil
    )
}

func testStaleRefreshCannotOverwriteNewEndpoint() async {
    let client = FakeFamiliarRosterClient(
        gate: .ready(pairedDaemon(host: "old")),
        result: .success([])
    )
    client.suspends = true
    let model = FamiliarSelectionModel(client: client)

    let first = Task { await model.refresh() }
    await fulfillment(of: [client.firstRequest], timeout: 1)
    client.gateResult = .ready(pairedDaemon(host: "new"))
    model.activate(.companion(host: "new", port: 7777))
    let second = Task { await model.refresh() }
    await fulfillment(of: [client.secondRequest], timeout: 1)

    client.resumeLast(with: .success([remoteFamiliar(id: "forge", name: "Forge")]))
    await second.value
    client.resumeFirst(with: .success([remoteFamiliar(id: "sage", name: "Sage")]))
    await first.value

    XCTAssertEqual(model.roster.map(\.id), ["forge"])
    XCTAssertEqual(model.companionProfile, .companion(host: "new", port: 7777))
}

func testSuccessfulRefreshClearsRemovedSelection() async throws {
    let defaults = UserDefaults(suiteName: "familiar-\(UUID().uuidString)")!
    let store = FamiliarSelectionStore(defaults: defaults)
    let profile = FamiliarProfileKey.companion(host: "mac", port: 7777)
    try store.save(
        FamiliarIdentity(id: "sage", displayName: "Sage", emoji: nil, role: "Guide"),
        for: profile
    )
    let client = FakeFamiliarRosterClient(
        gate: .ready(pairedDaemon(host: "mac")),
        result: .success([remoteFamiliar(id: "forge", name: "Forge")])
    )
    let model = FamiliarSelectionModel(client: client, store: store)
    model.activate(profile)

    await model.refresh()

    XCTAssertNil(model.selectedFamiliar)
    XCTAssertNil(try store.load(for: profile))
}

func testFailedRefreshRetainsCachedSelection() async throws {
    let defaults = UserDefaults(suiteName: "familiar-\(UUID().uuidString)")!
    let store = FamiliarSelectionStore(defaults: defaults)
    let profile = FamiliarProfileKey.codex(profileID: "account-a")
    let sage = FamiliarIdentity(
        id: "sage", displayName: "Sage", emoji: nil, role: "Guide"
    )
    try store.save(sage, for: profile)
    let client = FakeFamiliarRosterClient(
        gate: .ready(pairedDaemon()),
        result: .failure(.unavailable)
    )
    let model = FamiliarSelectionModel(client: client, store: store)
    model.activate(profile)

    await model.refresh()

    XCTAssertEqual(model.selectedFamiliar, sage)
    XCTAssertEqual(model.state, .failed(reason: "Roster unavailable"))
}
```

- [ ] **Step 2: Run the tests and verify failure**

Run the focused `FamiliarSelectionTests` command from Task 3.

Expected: compile failures for the model/client/state.

- [ ] **Step 3: Implement generation-safe roster refresh**

Add:

```swift
@MainActor
final class FamiliarSelectionModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(reason: String)
    }

    @Published private(set) var roster: [RemoteFamiliar] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var selectedFamiliar: FamiliarIdentity?

    private let client: any FamiliarRosterClient
    private let store: FamiliarSelectionStore
    private var generation: UInt64 = 0
    private var rosterByCompanionProfile: [FamiliarProfileKey: [RemoteFamiliar]] = [:]
    private(set) var companionProfile: FamiliarProfileKey?
    private(set) var activeProfile: FamiliarProfileKey?

    init(
        client: any FamiliarRosterClient,
        store: FamiliarSelectionStore = FamiliarSelectionStore()
    ) {
        self.client = client
        self.store = store
    }

    func activate(_ profile: FamiliarProfileKey?) {
        generation &+= 1
        activeProfile = profile
        guard let profile else {
            selectedFamiliar = nil
            return
        }
        do {
            selectedFamiliar = try store.load(for: profile)
        } catch {
            selectedFamiliar = nil
            state = .failed(reason: error.localizedDescription)
        }
    }

    func refresh() async {
        generation &+= 1
        let request = generation
        state = .loading
        let gate = await client.gate()
        guard request == generation else { return }
        guard case let .ready(pairing) = gate else {
            state = .failed(reason: "Pair with a daemon to load familiars.")
            return
        }
        let profile = FamiliarProfileKey.companion(host: pairing.host, port: pairing.port)
        if companionProfile != profile {
            companionProfile = profile
            roster = rosterByCompanionProfile[profile] ?? []
        }
        do {
            let loaded = try await client.familiars(pairing: pairing)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            guard request == generation else { return }
            roster = loaded
            rosterByCompanionProfile[profile] = loaded
            companionProfile = profile
            if let activeProfile {
                if let selected = try store.load(for: activeProfile),
                   let match = loaded.first(where: {
                       $0.id.caseInsensitiveCompare(selected.id) == .orderedSame
                   }) {
                    let refreshed = identity(for: match)
                    try store.save(refreshed, for: activeProfile)
                    selectedFamiliar = refreshed
                } else {
                    try store.save(nil, for: activeProfile)
                    selectedFamiliar = nil
                }
            }
            state = .loaded
        } catch {
            guard request == generation else { return }
            companionProfile = profile
            if let activeProfile {
                do {
                    selectedFamiliar = try store.load(for: activeProfile)
                } catch {
                    selectedFamiliar = nil
                    state = .failed(reason: error.localizedDescription)
                    return
                }
            }
            state = .failed(reason: error.localizedDescription)
        }
    }

    func select(id: String?, for profile: FamiliarProfileKey) {
        generation &+= 1
        activeProfile = profile
        do {
            let selected: FamiliarIdentity?
            if let id {
                guard let familiar = remoteFamiliar(for: id) else {
                    state = .failed(reason: "The selected familiar is no longer available.")
                    return
                }
                selected = identity(for: familiar)
            } else {
                selected = nil
            }
            try store.save(selected, for: profile)
            selectedFamiliar = selected
        } catch {
            state = .failed(reason: error.localizedDescription)
        }
    }

    func selection(for profile: FamiliarProfileKey) throws -> FamiliarIdentity? {
        try store.load(for: profile)
    }

    func remoteFamiliar(for id: String) -> RemoteFamiliar? {
        roster.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    private func identity(for familiar: RemoteFamiliar) -> FamiliarIdentity {
        FamiliarIdentity(
            id: familiar.id,
            displayName: familiar.displayName,
            emoji: familiar.emoji,
            role: familiar.role
        )
    }
}
```

Implement `LiveFamiliarRosterClient` by reusing the shared `CompanionModel`
gate and `PocketEngine.remoteFamiliars`.

- [ ] **Step 4: Run all familiar-selection tests**

Run the Task 3 focused test command.

Expected: all persistence and race tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/Support/FamiliarSelectionModel.swift \
  app/Tests/FamiliarSelectionTests.swift
git commit -m "feat(familiar): refresh daemon roster safely" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Task 5: Bind Companion Sessions to Familiar Identity

**Files:**
- Modify: `app/Sources/Support/ChatTypes.swift`
- Modify: `app/Sources/Support/CompanionSessionClient.swift`
- Modify: `app/Sources/Support/CompanionChatModel.swift`
- Modify: `app/Sources/Support/CompanionChatModel+Session.swift`
- Modify: `app/Sources/Support/CompanionChatModel+Cleanup.swift`
- Modify: `app/Tests/CompanionChatTestSupport.swift`
- Modify: `app/Tests/CompanionChatLifecycleTests.swift`

- [ ] **Step 1: Write the failing lifecycle regression**

Update the fake launch method to capture:

```swift
var launchedFamiliarIDs: [String?] = []
```

Add:

```swift
func testChangingFamiliarKillsOldSessionBeforeLaunchingReplacement() async {
    let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
    let model = CompanionChatModel(client: client)

    await model.send(prompt: "first", projectRoot: "/srv/repo", familiarID: "sage")
    await model.send(prompt: "second", projectRoot: "/srv/repo", familiarID: "forge")

    XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
}
```

- [ ] **Step 2: Run the focused lifecycle test and verify failure**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5' \
  -only-testing:CovenPocketTests/CompanionChatLifecycleTests test -quiet
```

Expected: compile failure because send/launch do not accept familiar IDs.

- [ ] **Step 3: Thread the optional familiar through the client**

Change the protocol and live implementation:

```swift
func launch(
    pairing: DaemonPairing,
    projectRoot: String,
    prompt: String,
    title: String,
    familiarID: String?
) async throws -> RemoteSession
```

Pass `familiarId: familiarID` to generated `remoteLaunchSession`.

- [ ] **Step 4: Bind reuse and retry to the familiar**

Add:

```swift
var sessionFamiliarID: String?
var retryFamiliarID: String?
```

Change `send` to accept and normalize `familiarID`. Store it with retry state.
Change `replaceSessionIfNeeded` so reuse requires both:

```swift
sessionProjectRoot == projectRoot && sessionFamiliarID == familiarID
```

Otherwise kill the current session using the existing fresh gate and retryable
cleanup behavior. Pass the familiar ID to `prepareAndLaunch`, assign
`sessionFamiliarID` only after the generation check, and clear it in
`abandonSession`. Retry must replay the stored `retryFamiliarID`.

- [ ] **Step 5: Run all companion chat tests**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5' \
  -only-testing:CovenPocketTests/CompanionChatTests \
  -only-testing:CovenPocketTests/CompanionChatLifecycleTests \
  -only-testing:CovenPocketTests/CompanionChatPollingTests \
  -only-testing:CovenPocketTests/CompanionChatAvailabilityTests test -quiet
```

Expected: all companion model tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/Support/ChatTypes.swift \
  app/Sources/Support/CompanionSessionClient.swift \
  app/Sources/Support/CompanionChatModel.swift \
  app/Sources/Support/CompanionChatModel+Session.swift \
  app/Sources/Support/CompanionChatModel+Cleanup.swift \
  app/Tests/CompanionChatTestSupport.swift \
  app/Tests/CompanionChatLifecycleTests.swift
git commit -m "feat(familiar): bind companion session identity" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Task 6: Wire On-Device Chat and SwiftUI

**Files:**
- Modify: `app/Sources/Support/ChatTypes.swift`
- Modify: `app/Sources/Support/ChatModel.swift`
- Modify: `app/Sources/Views/ChatView.swift`
- Modify: `app/Sources/Views/ChatSettingsView.swift`
- Create: `app/Sources/Views/FamiliarPickerSection.swift`
- Modify: `app/Tests/ChatSurfaceTests.swift`
- Modify: `app/Tests/FamiliarSelectionTests.swift`

- [ ] **Step 1: Write failing ChatModel identity tests**

Add:

```swift
func testNewCodexSessionResolvesMatchingSelectedSnapshot() {
    var settings = ChatSettings()
    settings.familiarID = "sage"
    let sage = FamiliarIdentity(
        id: "sage", displayName: "Sage", emoji: nil, role: "Guide"
    )

    XCTAssertEqual(
        ChatModel.familiarForNewSession(settings: settings, selected: sage),
        sage
    )
}

func testNewCodexSessionRejectsMismatchedSelectionSnapshot() {
    var settings = ChatSettings()
    settings.familiarID = "sage"
    let forge = FamiliarIdentity(
        id: "forge", displayName: "Forge", emoji: nil, role: "Builder"
    )

    XCTAssertNil(
        ChatModel.familiarForNewSession(settings: settings, selected: forge)
    )
}

func testResumePinsSettingsToStoredFamiliar() {
    let sage = FamiliarIdentity(
        id: "sage", displayName: "Sage", emoji: nil, role: "Guide"
    )
    let summary = ChatSessionSummary(
        sessionId: UUID().uuidString,
        title: "Stored",
        model: "gpt-5.6-sol",
        createdAt: "2026-07-30T00:00:00Z",
        updatedAt: "2026-07-30T00:00:00Z",
        messageCount: 1,
        familiar: sage
    )
    var settings = ChatSettings()
    settings.familiarID = "forge"

    let resumed = ChatModel.settingsForResume(summary, current: settings)

    XCTAssertEqual(resumed.familiarID, "sage")
}
```

Keep the actual Rust preamble assertion in Task 2; Swift tests assert argument
routing and session-setting behavior.

- [ ] **Step 2: Run focused Chat/familiar tests and verify failure**

Run:

```bash
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5' \
  -only-testing:CovenPocketTests/ChatSurfaceTests \
  -only-testing:CovenPocketTests/FamiliarSelectionTests test -quiet
```

Expected: compile or assertion failure until Chat wiring exists.

- [ ] **Step 3: Add familiar selection to Chat settings and model routing**

Add:

```swift
var familiarID: String?
```

to `ChatSettings`.

Add the tested routing helpers:

```swift
static func familiarForNewSession(
    settings: ChatSettings,
    selected: FamiliarIdentity?
) -> FamiliarIdentity? {
    guard settings.familiarID == selected?.id else { return nil }
    return selected
}

static func settingsForResume(
    _ summary: ChatSessionSummary,
    current: ChatSettings
) -> ChatSettings {
    var pinned = current
    pinned.familiarID = summary.familiar?.id
    return pinned
}
```

Construct one shared `CompanionModel` in `ChatView.init`, then build both
`CompanionChatModel` and `FamiliarSelectionModel` from it:

```swift
init() {
    let companion = CompanionModel()
    _companionModel = StateObject(
        wrappedValue: CompanionChatModel(companion: companion)
    )
    _familiarModel = StateObject(
        wrappedValue: FamiliarSelectionModel(
            client: LiveFamiliarRosterClient(companion: companion)
        )
    )
}
```

Before send, derive the active profile:

```swift
private var familiarProfile: FamiliarProfileKey? {
    switch settings.backend {
    case .codex:
        return client.codexAccount.map {
            .codex(profileID: $0.profileId)
        }
    case .companionClaude:
        guard case let .ready(pairing) = companionModel.availability else {
            return nil
        }
        return .companion(host: pairing.host, port: pairing.port)
    }
}
```

Change the on-device signature to:

```swift
func send(
    prompt: String,
    settings: ChatSettings,
    selectedFamiliar: FamiliarIdentity?
) async
```

Pass `ChatModel.familiarForNewSession(settings:selected:)` to generated
`startChat`. Pass the selected ID to `CompanionChatModel.send` for companion.

`resume` calls `settingsForResume` before assigning `sessionSettings`, and does
not pass current selection to generated `resumeChat` because Rust loads the
stored sidecar. Because `familiarID` is part of `ChatSettings` equality,
changing selection starts a new session.

- [ ] **Step 4: Build the focused picker view**

Create `FamiliarPickerSection.swift`:

```swift
import SwiftUI

struct FamiliarPickerSection: View {
    @Binding var settings: ChatSettings
    @ObservedObject var model: FamiliarSelectionModel
    let profile: FamiliarProfileKey?

    var body: some View {
        Section {
            Picker("Familiar", selection: $settings.familiarID) {
                Text("None").tag(Optional<String>.none)
                ForEach(model.roster, id: \.id) { familiar in
                    Text(label(for: familiar)).tag(Optional(familiar.id))
                }
            }
            .disabled(
                profile == nil || model.roster.isEmpty || model.state == .loading
            )
            .onChange(of: settings.familiarID) { _, id in
                guard let profile else { return }
                model.select(id: id, for: profile)
            }

            switch model.state {
            case .idle:
                Text("Familiars come from your paired Coven daemon.")
            case .loading:
                Label("Loading familiars…", systemImage: "sparkles")
            case .loaded where model.roster.isEmpty:
                Text("No familiars are configured on this daemon.")
            case .loaded:
                if let selected = model.selectedFamiliar {
                    LabeledContent("Identity", value: selected.displayName)
                    if let role = selected.role {
                        LabeledContent("Role", value: role)
                    }
                }
            case let .failed(reason):
                Text(reason).foregroundStyle(.secondary)
            }
        } header: {
            Text("Familiar")
        } footer: {
            Text("Familiars shape identity. They never widen iOS tools or permissions.")
        }
    }

    private func label(for familiar: RemoteFamiliar) -> String {
        let literalIcon = familiar.icon.flatMap {
            $0.hasPrefix("ph:") ? nil : $0
        }
        return [literalIcon ?? familiar.emoji, Optional(familiar.displayName)]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
```

Embed it in `ChatSettingsView`, refresh on task, and synchronize
`settings.familiarID` from `selection(for:)` whenever backend/profile changes.
Show the active familiar in a leading toolbar menu/label without adding a new
navigation surface.

Use a stable-profile synchronizer so the existing `.checking` availability
state cannot erase a companion choice:

```swift
private func synchronizeFamiliarProfile() {
    if settings.backend == .companionClaude,
       companionModel.availability == .checking {
        return
    }
    familiarModel.activate(familiarProfile)
    settings.familiarID = familiarModel.selectedFamiliar?.id
}
```

Call it after the initial roster refresh and from changes to backend, Codex
profile ID, and companion availability. Pass `familiarModel` into
`ChatSettingsView`; do not construct a second selection model in the sheet.

- [ ] **Step 5: Run focused tests**

Run the Step 2 command.

Expected: all Chat and familiar-selection tests pass.

- [ ] **Step 6: Run strict SwiftLint**

Run:

```bash
swiftlint lint --strict
```

Expected: zero violations.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/Support/ChatTypes.swift \
  app/Sources/Support/ChatModel.swift \
  app/Sources/Views/ChatView.swift \
  app/Sources/Views/ChatSettingsView.swift \
  app/Sources/Views/FamiliarPickerSection.swift \
  app/Tests/ChatSurfaceTests.swift \
  app/Tests/FamiliarSelectionTests.swift
git commit -m "feat(familiar): add chat identity picker" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Task 7: Review, Documentation, and Completion

**Files:**
- Modify: `ROADMAP.md`
- Modify after merge: `.beads/issues.jsonl`
- Test: all Rust and iOS tests

- [ ] **Step 1: Request fresh-context code review**

Review the full branch against `origin/main` for:

- identity/permission escalation;
- stale pairing/roster/session races;
- familiar switching inside a live conversation;
- malformed roster and sidecar handling;
- resume/fork identity drift; and
- generated-binding mismatches.

Fix all Critical and Important findings and add regressions before proceeding.

- [ ] **Step 2: Mark the upstream-aligned roadmap item complete**

Change:

```markdown
- [ ] Familiar companion (7 archetypes)
```

to:

```markdown
- [x] Familiar companion: daemon-owned roster selection, profile-scoped
      persistence, and session-pinned identity for on-device and companion Chat
```

- [ ] **Step 3: Run the immutable full gate**

Run:

```bash
./scripts/build-xcframework.sh
cd rust
cargo test -p coven-pocket-ffi
cargo check -p coven-pocket-ffi
cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings
cargo fmt --all --check
cd ..
swiftlint lint --strict
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5' test -quiet
xcodebuild -project CovenPocket.xcodeproj -scheme CovenPocket \
  -destination 'generic/platform=iOS Simulator' build -quiet
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 4: Commit the roadmap update**

Run:

```bash
git add ROADMAP.md
git commit -m "docs(familiar): mark roster companion complete" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

- [ ] **Step 5: Push, open the PR, and wait for CI**

```bash
git push -u origin feat/familiar-companion
gh pr create --base main --head feat/familiar-companion \
  --title "feat(familiar): add roster-driven chat identity" \
  --body "$(cat <<'EOF'
## Summary
- load the daemon-owned familiar roster and persist selection by Codex or companion profile
- pin familiar identity across on-device and daemon session lifecycle operations
- replace the obsolete seven-archetype roadmap wording with the upstream roster contract

## Validation
- `./scripts/build-xcframework.sh`
- `cd rust && cargo test -p coven-pocket-ffi`
- `cd rust && cargo check -p coven-pocket-ffi`
- `cd rust && cargo clippy -p coven-pocket-ffi --all-targets -- -D warnings`
- `cd rust && cargo fmt --all --check`
- `swiftlint lint --strict`
- iOS simulator test and generic simulator build
EOF
)"
gh pr checks --watch --interval 10
```

- [ ] **Step 6: Merge only after review and required checks pass**

Use the repository's squash merge convention, confirm the PR is `MERGED`, then

- [ ] **Step 7: Close the Bead on updated main with exact evidence**

Run:

```bash
git switch main
git pull --ff-only
PR_URL="$(gh pr list --head feat/familiar-companion --state merged \
  --json url --jq '.[0].url')"
bd close pocket-eba --reason \
  "Merged roster-driven familiar companion with daemon/on-device identity paths, profile persistence, session pinning, tests, lint, builds, and review passing"
bd comments add pocket-eba \
  "Merged PR: ${PR_URL}. Rust and iOS tests, strict lint, framework/app builds, and required CI passed. The obsolete seven-name roster was replaced by the daemon-owned roster contract."
git add .beads/issues.jsonl .beads/interactions.jsonl
git commit -m "chore(beads): audit familiar companion" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push origin main
```
