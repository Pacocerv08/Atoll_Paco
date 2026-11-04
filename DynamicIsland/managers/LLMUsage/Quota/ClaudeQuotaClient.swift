import Foundation

actor ClaudeCredentialStore {
    static let shared = ClaudeCredentialStore()
    private var cached: ClaudeQuotaClient.CredentialFile.OAuth?

    fileprivate func get() -> ClaudeQuotaClient.CredentialFile.OAuth? { cached }
    fileprivate func set(_ creds: ClaudeQuotaClient.CredentialFile.OAuth) { cached = creds }
}

struct ClaudeQuotaClient {
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }


    fileprivate struct CredentialFile: Decodable, Sendable {
        struct OAuth: Decodable, Sendable {
            let accessToken: String
            let refreshToken: String
            let expiresAt: Int64
        }
        let claudeAiOauth: OAuth
    }

    private enum ResetsAt: Decodable {
        case iso(String)
        case epochMs(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .iso(s) }
            else { self = .epochMs(try c.decode(Double.self)) }
        }
        var date: Date? {
            switch self {
            case .iso(let s): return ISO8601DateFormatter().date(from: s)
            case .epochMs(let ms): return Date(timeIntervalSince1970: ms / 1000)
            }
        }
    }

    private struct Window: Decodable {
        let utilization: Double
        let resetsAt: ResetsAt
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
    }

    func fetchLimits() async -> (session: UsageLimit?, week: UsageLimit?) {
        guard let creds = await currentCredentials() else { return (nil, nil) }
        guard let token = await validAccessToken(creds) else { return (nil, nil) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return (nil, nil) }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(UsageResponse.self, from: data)
            let sessionLimit = decoded.fiveHour.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            let weekLimit = decoded.sevenDay.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            return (sessionLimit, weekLimit)
        } catch {
            return (nil, nil)
        }
    }

    private func currentCredentials() async -> CredentialFile.OAuth? {
        if let cached = await ClaudeCredentialStore.shared.get() { return cached }
        guard let loaded = Self.loadCredentialsFromSource() else { return nil }
        await ClaudeCredentialStore.shared.set(loaded)
        return loaded
    }

    // File first never prompts; Keychain only as fallback.
    private static func loadCredentialsFromSource() -> CredentialFile.OAuth? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONDecoder().decode(CredentialFile.self, from: data) {
            return parsed.claudeAiOauth
        }
        guard let json = KeychainReader.genericPassword(service: "Claude Code-credentials"),
              let parsed = try? JSONDecoder().decode(CredentialFile.self, from: Data(json.utf8)) else { return nil }
        return parsed.claudeAiOauth
    }

    // Atoll_Paco: ya no se renueva el token. La versión original pedía un token
    // nuevo pero no lo guardaba de regreso, y como el refresh token viejo queda
    // invalidado, Claude Code se quedaba sin sesión. Ahora solo se usa el token
    // vigente; si expiró se vuelve a leer del archivo/Keychain (Claude Code lo
    // renueva solo) y si sigue expirado no se muestra el límite.
    private func validAccessToken(_ creds: CredentialFile.OAuth) async -> String? {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if creds.expiresAt > nowMs { return creds.accessToken }
        guard let fresh = Self.loadCredentialsFromSource(), fresh.expiresAt > nowMs else { return nil }
        await ClaudeCredentialStore.shared.set(fresh)
        return fresh.accessToken
    }
}
