import Foundation

@MainActor
protocol CompanionSessionClient: AnyObject {
    func sessionGate() async -> CompanionModel.SessionGate
    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String,
        familiarID: String?
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
        companion.reloadPairing()
        return await companion.gateForSessionTraffic()
    }

    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String,
        familiarID: String?
    ) async throws -> RemoteSession {
        try await companion.engine.remoteLaunchSession(
            host: pairing.host,
            port: pairing.port,
            projectRoot: projectRoot,
            prompt: prompt,
            title: title,
            familiarId: familiarID,
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
