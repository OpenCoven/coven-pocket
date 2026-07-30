import XCTest
@testable import CovenPocket

enum FakeCompanionError: LocalizedError {
    case polling
    case sessionNotLive
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .polling:
            return "Polling failed"
        case .sessionNotLive:
            return "engine error: Session is not running."
        case .sessionNotFound:
            return "engine error: Session was not found."
        }
    }
}

@MainActor
final class FakeCompanionSessionClient: CompanionSessionClient {
    var gate: CompanionModel.SessionGate
    var launchedPrompts: [String] = []
    var sentInputs: [String] = []
    var killedSessionIDs: [String] = []
    var gateCallCount = 0
    var eventBatches: [RemoteEventBatch] = []
    var eventError: FakeCompanionError?
    var sendInputError: FakeCompanionError?
    var killError: FakeCompanionError?
    var launchError: FakeCompanionError?
    var launchedProjectRoot: String?
    var suspendsEvents = false
    var suspendsGate = false
    var suspendsLaunch = false
    var suspendsKill = false
    let eventsRequested = XCTestExpectation(description: "events requested")
    let gateRequested = XCTestExpectation(description: "session gate requested")
    let secondGateRequested = XCTestExpectation(description: "second session gate requested")
    let launchRequested = XCTestExpectation(description: "session launch requested")
    let killRequested = XCTestExpectation(description: "session kill requested")
    private var eventsContinuation: CheckedContinuation<RemoteEventBatch, Never>?
    private var gateContinuations: [
        CheckedContinuation<CompanionModel.SessionGate, Never>
    ] = []
    private var launchContinuation: CheckedContinuation<RemoteSession, Error>?
    private var killContinuation: CheckedContinuation<Void, Never>?

    init(gate: CompanionModel.SessionGate) {
        self.gate = gate
    }

    func sessionGate() async -> CompanionModel.SessionGate {
        gateCallCount += 1
        if suspendsGate {
            if gateContinuations.isEmpty {
                gateRequested.fulfill()
            } else {
                secondGateRequested.fulfill()
            }
            return await withCheckedContinuation { continuation in
                gateContinuations.append(continuation)
            }
        }
        return gate
    }

    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String
    ) async throws -> RemoteSession {
        launchedPrompts.append(prompt)
        let session = RemoteSession(
            id: "session-1",
            harness: "claude",
            title: title,
            status: "running",
            projectRoot: launchedProjectRoot ?? projectRoot,
            createdAt: "c",
            updatedAt: "u",
            familiarId: nil
        )
        if suspendsLaunch {
            launchRequested.fulfill()
            return try await withCheckedThrowingContinuation { continuation in
                launchContinuation = continuation
            }
        }
        if let launchError {
            throw launchError
        }
        return session
    }

    func events(
        pairing: DaemonPairing,
        sessionID: String,
        afterSeq: Int64
    ) async throws -> RemoteEventBatch {
        if suspendsEvents {
            eventsRequested.fulfill()
            return await withCheckedContinuation { continuation in
                eventsContinuation = continuation
            }
        }
        if let eventError {
            throw eventError
        }
        if eventBatches.isEmpty {
            return RemoteEventBatch(
                events: [],
                nextAfterSeq: afterSeq,
                hasMore: false
            )
        }
        return eventBatches.removeFirst()
    }

    func sendInput(
        pairing: DaemonPairing,
        sessionID: String,
        data: String
    ) async throws {
        if let sendInputError {
            throw sendInputError
        }
        sentInputs.append(data)
    }

    func kill(pairing: DaemonPairing, sessionID: String) async throws {
        if suspendsKill {
            killRequested.fulfill()
            await withCheckedContinuation { continuation in
                killContinuation = continuation
            }
        }
        if let killError {
            throw killError
        }
        killedSessionIDs.append(sessionID)
    }

    func resumeEvents(with batch: RemoteEventBatch) {
        let continuation = eventsContinuation
        eventsContinuation = nil
        continuation?.resume(returning: batch)
    }

    func resumeGate() {
        suspendsGate = false
        let continuations = gateContinuations
        gateContinuations = []
        continuations.forEach { $0.resume(returning: gate) }
    }

    func resumeNextGate(with result: CompanionModel.SessionGate) {
        guard !gateContinuations.isEmpty else { return }
        let continuation = gateContinuations.removeFirst()
        continuation.resume(returning: result)
    }

    func resumeLastGate(with result: CompanionModel.SessionGate) {
        guard let continuation = gateContinuations.popLast() else { return }
        continuation.resume(returning: result)
    }

    func resumeLaunch(projectRoot: String = "/srv/repo") {
        suspendsLaunch = false
        let continuation = launchContinuation
        launchContinuation = nil
        if let launchError {
            continuation?.resume(throwing: launchError)
        } else {
            continuation?.resume(
                returning: RemoteSession(
                    id: "session-1",
                    harness: "claude",
                    title: "title",
                    status: "running",
                    projectRoot: projectRoot,
                    createdAt: "c",
                    updatedAt: "u",
                    familiarId: nil
                )
            )
        }
    }

    func resumeKill() {
        suspendsKill = false
        let continuation = killContinuation
        killContinuation = nil
        continuation?.resume()
    }
}

func pairedDaemon(
    host: String = "mac.tailnet.ts.net",
    pid: UInt32 = 42,
    startedAt: String = "now"
) -> DaemonPairing {
    DaemonPairing(
        host: host,
        port: 7777,
        apiVersion: "coven.daemon.v1",
        covenVersion: "0.7.0",
        pid: pid,
        startedAt: startedAt,
        pairedAt: Date()
    )
}

func daemonOutputEvent(seq: Int64, data: String) throws -> RemoteEvent {
    let payload = try JSONSerialization.data(withJSONObject: ["data": data])
    guard let payloadJSON = String(data: payload, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return RemoteEvent(
        seq: seq,
        kind: "output",
        payloadJson: payloadJSON,
        createdAt: "t"
    )
}
