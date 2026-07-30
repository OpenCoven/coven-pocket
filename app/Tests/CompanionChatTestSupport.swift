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
    var launchedFamiliarIDs: [String?] = []
    var launchedPairings: [DaemonPairing] = []
    var sentInputs: [String] = []
    var sentInputPairings: [DaemonPairing] = []
    var killedSessionIDs: [String] = []
    var killPairings: [DaemonPairing] = []
    var eventPairings: [DaemonPairing] = []
    var operationLog: [String] = []
    var gateCallCount = 0
    var eventBatches: [RemoteEventBatch] = []
    var eventError: FakeCompanionError?
    var sendInputError: FakeCompanionError?
    var killError: FakeCompanionError?
    var killChecksCancellation = false
    var launchError: FakeCompanionError?
    var launchedProjectRoot: String?
    var launchResponseID = "session-1"
    var echoesRequestedFamiliarID = true
    var launchResponseFamiliarID: String?
    var suspendsEvents = false
    var suspendsGate = false
    var suspendsLaunch = false
    var suspendsSendInput = false
    var suspendsKill = false
    var beforeGateResponse: (() -> Void)?
    let eventsRequested = XCTestExpectation(description: "events requested")
    let gateRequested = XCTestExpectation(description: "session gate requested")
    let secondGateRequested = XCTestExpectation(description: "second session gate requested")
    let launchRequested = XCTestExpectation(description: "session launch requested")
    let secondLaunchRequested = XCTestExpectation(description: "second session launch requested")
    let sendInputRequested = XCTestExpectation(description: "session input requested")
    let killRequested = XCTestExpectation(description: "session kill requested")
    private var eventsContinuation: CheckedContinuation<RemoteEventBatch, Never>?
    private var gateContinuations: [
        CheckedContinuation<CompanionModel.SessionGate, Never>
    ] = []
    private var launchContinuation: CheckedContinuation<RemoteSession, Error>?
    private var sendInputContinuation: CheckedContinuation<Void, Never>?
    private var killContinuation: CheckedContinuation<Void, Never>?
    private var suspendedLaunchFamiliarID: String?
    private var launchCallCount = 0

    init(gate: CompanionModel.SessionGate) {
        self.gate = gate
    }

    func sessionGate() async -> CompanionModel.SessionGate {
        gateCallCount += 1
        let result: CompanionModel.SessionGate
        if suspendsGate {
            if gateContinuations.isEmpty {
                gateRequested.fulfill()
            } else {
                secondGateRequested.fulfill()
            }
            result = await withCheckedContinuation { continuation in
                gateContinuations.append(continuation)
            }
        } else {
            result = gate
        }
        let responseHook = beforeGateResponse
        beforeGateResponse = nil
        responseHook?()
        return result
    }

    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String,
        familiarID: String?
    ) async throws -> RemoteSession {
        launchCallCount += 1
        if launchCallCount == 2 {
            secondLaunchRequested.fulfill()
        }
        launchedPrompts.append(prompt)
        launchedFamiliarIDs.append(familiarID)
        launchedPairings.append(pairing)
        operationLog.append("launch:\(familiarID ?? "nil")")
        if suspendsLaunch {
            suspendedLaunchFamiliarID = familiarID
            launchRequested.fulfill()
            return try await withCheckedThrowingContinuation { continuation in
                launchContinuation = continuation
            }
        }
        if let launchError {
            throw launchError
        }
        return remoteSession(
            id: launchResponseID,
            title: title,
            projectRoot: launchedProjectRoot ?? projectRoot,
            familiarID: responseFamiliarID(for: familiarID)
        )
    }

    func events(
        pairing: DaemonPairing,
        sessionID: String,
        afterSeq: Int64
    ) async throws -> RemoteEventBatch {
        eventPairings.append(pairing)
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
        sentInputPairings.append(pairing)
        if suspendsSendInput {
            sendInputRequested.fulfill()
            await withCheckedContinuation { continuation in
                sendInputContinuation = continuation
            }
        }
    }

    func kill(pairing: DaemonPairing, sessionID: String) async throws {
        operationLog.append("kill:\(sessionID)")
        killPairings.append(pairing)
        if suspendsKill {
            killRequested.fulfill()
            await withCheckedContinuation { continuation in
                killContinuation = continuation
            }
        }
        if killChecksCancellation {
            try Task.checkCancellation()
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

    func resumeLaunch(
        id: String = "session-1",
        projectRoot: String = "/srv/repo"
    ) {
        suspendsLaunch = false
        let continuation = launchContinuation
        launchContinuation = nil
        let familiarID = suspendedLaunchFamiliarID
        suspendedLaunchFamiliarID = nil
        if let launchError {
            continuation?.resume(throwing: launchError)
        } else {
            continuation?.resume(
                returning: remoteSession(
                    id: id,
                    title: "title",
                    projectRoot: projectRoot,
                    familiarID: responseFamiliarID(for: familiarID)
                )
            )
        }
    }

    func resumeSendInput() {
        suspendsSendInput = false
        let continuation = sendInputContinuation
        sendInputContinuation = nil
        continuation?.resume()
    }

    func resumeKill() {
        suspendsKill = false
        let continuation = killContinuation
        killContinuation = nil
        continuation?.resume()
    }

    private func responseFamiliarID(for requested: String?) -> String? {
        echoesRequestedFamiliarID ? requested : launchResponseFamiliarID
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

@MainActor
func verifiedPairingToken(
    _ pairing: DaemonPairing,
    on model: CompanionChatModel
) -> VerifiedPairing {
    VerifiedPairing(
        pairing: pairing,
        availabilityGeneration: model.availabilityGeneration
    )
}

@MainActor
func completeTurn(on model: CompanionChatModel) {
    model.apply(events: [
        RemoteEvent(
            seq: 1,
            kind: "result",
            payloadJson: #"{"type":"result","is_error":false}"#,
            createdAt: "t"
        )
    ])
}

func remoteSession(
    id: String = "session-1",
    title: String = "title",
    projectRoot: String = "/srv/repo",
    familiarID: String? = nil
) -> RemoteSession {
    RemoteSession(
        id: id,
        harness: "claude",
        title: title,
        status: "running",
        projectRoot: projectRoot,
        createdAt: "c",
        updatedAt: "u",
        familiarId: familiarID
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
