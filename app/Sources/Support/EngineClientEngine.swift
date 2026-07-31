import Foundation

protocol EngineClientEngine: Sendable {
    func engineVersion() -> String
    func defaultModel() -> String
    func defaultCodexModel() -> String
    func codexAccount() -> CodexAccount?
    func listModels(apiKey: String) async throws -> [PocketModel]
    func listCodexModels() async throws -> [PocketModel]
    func codexLogin(delegate: CodexAuthDelegate) async throws -> CodexAccount
    func codexLogout() throws
    // swiftlint:disable:next function_parameter_count
    func streamPrompt(
        provider: PocketProvider,
        apiKey: String,
        model: String,
        prompt: String,
        effort: String?,
        delegate: StreamDelegate
    ) async throws
}

extension PocketEngine: EngineClientEngine {}
