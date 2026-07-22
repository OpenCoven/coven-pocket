import Foundation

/// A gist this device created, kept so the user can revoke it later.
struct GistShare: Codable, Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    let createdAt: Date
}

/// The two GitHub calls sharing needs. Tests substitute a fake.
protocol GistAPI {
    func create(
        title: String, filename: String, content: String, token: String
    ) async throws -> GistShare
    func delete(id: String, token: String) async throws
}

/// Wire shape of a created gist (`POST /gists` response subset).
private struct CreatedGist: Decodable {
    let id: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case htmlUrl = "html_url"
    }
}

/// Thin `api.github.com` client. Unlisted ("secret") gists only.
struct GistClient: GistAPI {
    struct RequestFailed: LocalizedError {
        let status: Int
        let detail: String

        var errorDescription: String? {
            "GitHub returned \(status): \(detail)"
        }
    }

    func create(
        title: String, filename: String, content: String, token: String
    ) async throws -> GistShare {
        let body: [String: Any] = [
            "description": title,
            "public": false,
            "files": [filename: ["content": content]]
        ]
        var request = URLRequest(url: URL(string: "https://api.github.com/gists")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        apply(token: token, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            throw RequestFailed(status: status, detail: Self.errorDetail(data))
        }
        let created = try JSONDecoder().decode(CreatedGist.self, from: data)
        return GistShare(id: created.id, url: created.htmlUrl, title: title, createdAt: .now)
    }

    func delete(id: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/gists/\(id)")!)
        request.httpMethod = "DELETE"
        apply(token: token, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 means it is already gone — revoked is revoked.
        guard status == 204 || status == 404 else {
            throw RequestFailed(status: status, detail: Self.errorDetail(data))
        }
    }

    private func apply(token: String, to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    private static func errorDetail(_ data: Data) -> String {
        struct Detail: Decodable { let message: String }
        return (try? JSONDecoder().decode(Detail.self, from: data))?.message
            ?? "unexpected response"
    }
}

/// Drives the share sheet: redacted preview, upload, and revocation.
///
/// The preview shown to the user is byte-identical to what uploads — both
/// come from the engine's `redactSecrets` output, never the raw transcript.
@MainActor
final class GistShareModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case ready
        case uploading
        case shared(GistShare)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var preview = ""
    @Published private(set) var findings: [RedactionFinding] = []
    @Published private(set) var pastShares: [GistShare] = []
    @Published var token: String {
        didSet {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Keychain.delete(Self.tokenKey)
            } else {
                Keychain.set(trimmed, for: Self.tokenKey)
            }
        }
    }

    private var title = ""
    private let api: GistAPI
    private let engine: PocketEngine
    private let defaults: UserDefaults

    static let tokenKey = "gist-token"
    static let sharesKey = "gist-shares"

    init(
        api: GistAPI = GistClient(),
        engine: PocketEngine = PocketEngine(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.engine = engine
        self.defaults = defaults
        // A workspace token may already exist; gists need `gist` scope, so
        // it stays editable rather than assumed.
        token = Keychain.get(Self.tokenKey) ?? Keychain.get(RepoModel.tokenKey) ?? ""
        pastShares = Self.loadShares(from: defaults)
    }

    /// Render + redact the transcript. Upload stays disabled until this
    /// completes, so raw text can never leave the device.
    func prepare(items: [ChatItem]) async {
        phase = .preparing
        title = SessionExport.title(for: items)
        let markdown = SessionExport.markdown(title: title, items: items)
        do {
            let result = try await engine.redactSecrets(text: markdown)
            preview = result.redacted
            findings = result.findings
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func upload() async {
        guard phase == .ready else { return }
        let token = effectiveToken
        guard !token.isEmpty else {
            phase = .failed("Add a GitHub token with the gist scope first.")
            return
        }
        phase = .uploading
        do {
            let share = try await api.create(
                title: title,
                filename: "session.md",
                content: preview,
                token: token
            )
            pastShares.insert(share, at: 0)
            persistShares()
            phase = .shared(share)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Retry after a failure without re-rendering (the preview is intact).
    func resetToReady() {
        if case .failed = phase, !preview.isEmpty { phase = .ready }
    }

    func revoke(_ share: GistShare) async {
        let token = effectiveToken
        guard !token.isEmpty else {
            phase = .failed("Add a GitHub token with the gist scope first.")
            return
        }
        do {
            try await api.delete(id: share.id, token: token)
            pastShares.removeAll { $0.id == share.id }
            persistShares()
            if case .shared(let current) = phase, current.id == share.id {
                phase = preview.isEmpty ? .preparing : .ready
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private var effectiveToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistShares() {
        defaults.set(try? JSONEncoder().encode(pastShares), forKey: Self.sharesKey)
    }

    private static func loadShares(from defaults: UserDefaults) -> [GistShare] {
        guard let data = defaults.data(forKey: sharesKey) else { return [] }
        return (try? JSONDecoder().decode([GistShare].self, from: data)) ?? []
    }
}
