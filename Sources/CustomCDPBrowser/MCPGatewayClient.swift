import Foundation

struct MCPGatewayClient {
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
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 0.8

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func release(profile: CDPProfile) async throws -> Bool {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw MCPGatewayError.missingToken
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("release"))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["profile": profile.id])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPGatewayError.badStatus((response as? HTTPURLResponse)?.statusCode)
        }

        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return payload?["released"] as? Bool ?? false
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
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "GABRIEL_BROWSERS_MCP_TOKEN" else { return nil }
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first
    }
}

enum MCPGatewayError: LocalizedError {
    case missingToken
    case badStatus(Int?)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Token do Gateway MCP indisponível."
        case .badStatus(let statusCode):
            if let statusCode {
                "Gateway MCP retornou HTTP \(statusCode)."
            } else {
                "Gateway MCP não respondeu corretamente."
            }
        }
    }
}
