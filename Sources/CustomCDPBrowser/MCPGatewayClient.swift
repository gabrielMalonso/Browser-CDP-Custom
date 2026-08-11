import Foundation

struct GatewayCapabilities: Decodable, Equatable {
    let controlAPI: Int
    let leases: Bool
    let browserLifecycle: Bool

    enum CodingKeys: String, CodingKey {
        case leases, browserLifecycle
        case controlAPI = "controlApi"
    }
}

struct GatewayHealth: Decodable, Equatable {
    let version: String
    let capabilities: GatewayCapabilities

    var isCompatible: Bool {
        capabilities.controlAPI == 1 && capabilities.leases && capabilities.browserLifecycle
    }
}

struct GatewayProfileStatus: Decodable, Equatable {
    let id: String
    let name: String
    let port: Int
    let endpoint: String
    let defaultURL: String?
    let browser: GatewayBrowserStatus
    let worker: GatewayWorkerStatus?

    enum CodingKeys: String, CodingKey {
        case id, name, port, endpoint, browser, worker
        case defaultURL = "defaultUrl"
    }
}

struct GatewayBrowserStatus: Decodable, Equatable {
    let state: String
    let cdpAlive: Bool
    let processIDs: [Int]
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case state, cdpAlive, detail
        case processIDs = "processIds"
    }
}

struct GatewayWorkerStatus: Decodable, Equatable {
    let pid: Int?
    let callsInFlight: Int
    let leaseCount: Int
    let idleMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case pid, callsInFlight, leaseCount
        case idleMilliseconds = "idleMs"
    }
}

struct MCPGatewayClient {
    private struct ProfilesResponse: Decodable {
        let profiles: [GatewayProfileStatus]
    }

    private struct ReleaseResponse: Decodable {
        let released: Bool
    }

    private struct StopResponse: Decodable {
        let stopped: Bool
    }

    private struct EmptyResponse: Decodable {}

    private let baseURL: URL
    private let tokenProvider: () -> String?
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8787")!,
        tokenProvider: @escaping () -> String? = { Self.gatewayToken() },
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func isHealthy() async -> Bool {
        do {
            try await assertCompatible()
            return true
        } catch {
            return false
        }
    }

    func profiles() async throws -> [GatewayProfileStatus] {
        try await assertCompatible()
        return try await request("GET", path: "/v1/profiles", response: ProfilesResponse.self).profiles
    }

    func start(profile: CDPProfile) async throws {
        try await assertCompatible()
        _ = try await request(
            "POST",
            path: "/v1/profiles/\(profile.id)/start",
            body: [:],
            response: EmptyResponse.self
        )
    }

    func stop(profile: CDPProfile) async throws -> Bool {
        try await assertCompatible()
        return try await request(
            "POST",
            path: "/v1/profiles/\(profile.id)/stop",
            body: ["force": false],
            response: StopResponse.self
        ).stopped
    }

    func openURL(_ url: URL, in profile: CDPProfile) async throws {
        try await assertCompatible()
        _ = try await request(
            "POST",
            path: "/v1/profiles/\(profile.id)/open-url",
            body: ["url": url.absoluteString, "owner": "custom-cdp-browser"],
            response: EmptyResponse.self
        )
    }

    func release(profile: CDPProfile) async throws -> Bool {
        try await assertCompatible()
        return try await request(
            "POST",
            path: "/v1/profiles/\(profile.id)/worker/release",
            body: [:],
            response: ReleaseResponse.self
        ).released
    }

    private func assertCompatible() async throws {
        var request = URLRequest(url: url(for: "/health"))
        request.timeoutInterval = 0.8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw MCPGatewayError.badStatus((response as? HTTPURLResponse)?.statusCode, nil)
            }
            let health = try JSONDecoder().decode(GatewayHealth.self, from: data)
            guard health.isCompatible else { throw MCPGatewayError.incompatible(health.version) }
        } catch let error as MCPGatewayError {
            throw error
        } catch is DecodingError {
            throw MCPGatewayError.incompatible(nil)
        } catch {
            throw MCPGatewayError.unavailable(error.localizedDescription)
        }
    }

    private func request<Response: Decodable>(
        _ method: String,
        path: String,
        body: [String: Any]? = nil,
        response: Response.Type
    ) async throws -> Response {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw MCPGatewayError.missingToken
        }

        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, urlResponse) = try await session.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else {
                throw MCPGatewayError.badStatus(nil, nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                throw MCPGatewayError.badStatus(http.statusCode, payload?["error"] as? String)
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as MCPGatewayError {
            throw error
        } catch {
            throw MCPGatewayError.unavailable(error.localizedDescription)
        }
    }

    private func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    static func gatewayToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFilePath: String = "~/.codex/gabriel-browsers-mcp.env"
    ) -> String? {
        if let token = environment["GABRIEL_BROWSERS_MCP_TOKEN"], !token.isEmpty {
            return token
        }

        let expandedPath = NSString(string: envFilePath).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }

        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "export ", with: "", options: [.anchored])
                let parts = normalized.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "GABRIEL_BROWSERS_MCP_TOKEN" else { return nil }
                return parts[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            .first
    }
}

enum MCPGatewayError: LocalizedError {
    case missingToken
    case incompatible(String?)
    case badStatus(Int?, String?)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Token do supervisor de navegadores indisponível."
        case .incompatible(let version):
            if let version {
                "Supervisor de navegadores \(version) incompatível. Atualize para 0.2.1 ou superior."
            } else {
                "Supervisor de navegadores incompatível. Atualize para 0.2.1 ou superior."
            }
        case .badStatus(let statusCode, let detail):
            if let detail {
                detail
            } else if let statusCode {
                "Supervisor de navegadores retornou HTTP \(statusCode)."
            } else {
                "Supervisor de navegadores não respondeu corretamente."
            }
        case .unavailable(let detail):
            "Supervisor de navegadores indisponível: \(detail)"
        }
    }
}
