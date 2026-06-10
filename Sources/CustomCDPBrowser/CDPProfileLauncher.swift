import Foundation

struct CDPAttachedClient: Equatable, Hashable {
    let processID: String
    let command: String
}

enum CDPProcessInspector {
    static func establishedLsofArguments(for port: Int) -> [String] {
        ["-nP", "-tiTCP:\(port)", "-sTCP:ESTABLISHED"]
    }

    static func processListArguments() -> [String] {
        ["-axo", "pid=,command="]
    }

    static func psCommandArguments(for processID: String) -> [String] {
        ["-ww", "-p", processID, "-o", "command="]
    }

    static func uniqueProcessIDs(from output: String) -> [String] {
        var seen = Set<String>()
        var processIDs: [String] = []

        for processID in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard !processID.isEmpty, seen.insert(processID).inserted else { continue }
            processIDs.append(processID)
        }

        return processIDs
    }

    static func isPlaywrightMCPCommand(_ command: String, for port: Int) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.contains(where: { $0 == "playwright-mcp" || $0.hasSuffix("/playwright-mcp") }) else {
            return false
        }

        let endpoints = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)",
        ]

        for index in tokens.indices where tokens[index] == "--cdp-endpoint" {
            let nextIndex = tokens.index(after: index)
            if nextIndex < tokens.endIndex, endpoints.contains(tokens[nextIndex]) {
                return true
            }
        }

        return endpoints.contains { tokens.contains("--cdp-endpoint=\($0)") }
    }

    static func processCommands(from output: String) -> [String: String] {
        var commandsByProcessID: [String: String] = [:]

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmedLine.firstIndex(where: \.isWhitespace) else { continue }

            let processID = String(trimmedLine[..<separator])
            let command = String(trimmedLine[separator...]).trimmingCharacters(in: .whitespaces)
            guard !processID.isEmpty, !command.isEmpty else { continue }
            commandsByProcessID[processID] = command
        }

        return commandsByProcessID
    }

    static func clients(from commandsByProcessID: [String: String], port: Int) -> [CDPAttachedClient] {
        commandsByProcessID
            .filter { isPlaywrightMCPCommand($0.value, for: port) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { CDPAttachedClient(processID: $0.key, command: $0.value) }
    }

    static func attachedMCPClients(on port: Int) throws -> [CDPAttachedClient] {
        try clients(from: processCommands(), port: port)
    }

    static func attachedMCPClientsByPort(_ ports: [Int]) throws -> [Int: [CDPAttachedClient]] {
        let commands = try processCommands()
        return Dictionary(uniqueKeysWithValues: ports.map { port in
            (port, clients(from: commands, port: port))
        })
    }

    static func processIDsListening(on port: Int) throws -> [String] {
        let output = try output(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN"],
            emptyStatus: 1,
            failure: LauncherError.processLookupFailed(port)
        )

        return uniqueProcessIDs(from: output)
    }

    static func terminate(processIDs: [String]) throws {
        guard !processIDs.isEmpty else { return }

        _ = try output(
            executablePath: "/bin/kill",
            arguments: processIDs,
            failure: LauncherError.processTerminationFailed
        )
    }

    static func terminateMCPClients(processIDs: [String]) {
        for processID in processIDs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/kill")
            process.arguments = [processID]
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    private static func processIDsWithEstablishedConnections(on port: Int) throws -> [String] {
        let output = try output(
            executablePath: "/usr/sbin/lsof",
            arguments: establishedLsofArguments(for: port),
            emptyStatus: 1,
            failure: LauncherError.mcpClientLookupFailed(port)
        )

        return uniqueProcessIDs(from: output)
    }

    private static func processCommands() throws -> [String: String] {
        let output = try output(
            executablePath: "/bin/ps",
            arguments: processListArguments(),
            failure: LauncherError.mcpClientLookupFailed(nil)
        )

        return processCommands(from: output)
    }

    private static func command(forProcessID processID: String) throws -> String? {
        do {
            let output = try output(
                executablePath: "/bin/ps",
                arguments: psCommandArguments(for: processID),
                emptyStatus: 1,
                failure: LauncherError.mcpClientLookupFailed(nil)
            )

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch LauncherError.mcpClientLookupFailed {
            return nil
        }
    }

    private static func output(
        executablePath: String,
        arguments: [String],
        emptyStatus: Int? = nil,
        failure: Error
    ) throws -> String {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let emptyStatus, process.terminationStatus == emptyStatus {
            return ""
        }

        guard process.terminationStatus == 0 else {
            throw failure
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

@MainActor
final class CDPProfileLauncher: ObservableObject {
    static let shared = CDPProfileLauncher()

    @Published private(set) var runningProfileIDs: Set<String> = []
    @Published private(set) var mcpClientsByProfileID: [String: [CDPAttachedClient]] = [:]

    private let fileManager = FileManager.default
    private var refreshGeneration = 0

    func refreshStatuses() {
        refreshGeneration += 1
        let generation = refreshGeneration

        Task {
            var running = Set<String>()
            var mcpClientsByProfileID: [String: [CDPAttachedClient]] = [:]
            let mcpClientsByPort = (try? CDPProcessInspector.attachedMCPClientsByPort(
                CDPProfile.visibleProfiles.map(\.port)
            )) ?? [:]

            await withTaskGroup(of: (String, Bool, [CDPAttachedClient]).self) { group in
                for profile in CDPProfile.visibleProfiles {
                    let mcpClients = mcpClientsByPort[profile.port] ?? []
                    group.addTask {
                        let isRunning = await Self.checkEndpoint(profile.endpoint)
                        return (profile.id, isRunning, mcpClients)
                    }
                }

                for await (id, isRunning, mcpClients) in group {
                    if isRunning {
                        running.insert(id)
                    }

                    if !mcpClients.isEmpty {
                        mcpClientsByProfileID[id] = mcpClients
                    }
                }
            }

            await MainActor.run {
                guard self.refreshGeneration == generation else { return }
                self.runningProfileIDs = running
                self.mcpClientsByProfileID = mcpClientsByProfileID
            }
        }
    }

    func open(_ profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        ensureRunning(profile, initialURL: nil, completion: completion)
    }

    func ensureRunning(_ profile: CDPProfile, initialURL: URL?, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            cleanLocks(for: profile)
            try launchBrowser(for: profile, initialURL: initialURL)

            Task {
                let ok = await Self.waitForEndpoint(profile.endpoint)
                await MainActor.run {
                    self.refreshStatuses()
                    if ok {
                        completion(.success(()))
                    } else {
                        completion(.failure(LauncherError.endpointDidNotRespond(profile.port)))
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    func openURL(_ url: URL, in profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            if await Self.checkEndpoint(profile.endpoint) {
                do {
                    try await Self.openNewTab(url, port: profile.port)

                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.success(()))
                    }
                } catch {
                    await MainActor.run {
                        completion(.failure(error))
                    }
                }
                return
            }

            await MainActor.run {
                self.ensureRunning(profile, initialURL: url, completion: completion)
            }
        }
    }

    func close(_ profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                let processIDs = try CDPProcessInspector.processIDsListening(on: profile.port)
                guard !processIDs.isEmpty else {
                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.success(()))
                    }
                    return
                }

                try CDPProcessInspector.terminate(processIDs: processIDs)
                let didClose = await Self.waitForEndpointToStop(profile.endpoint)

                await MainActor.run {
                    self.refreshStatuses()
                    if didClose {
                        completion(.success(()))
                    } else {
                        completion(.failure(LauncherError.endpointStillResponding(profile.port)))
                    }
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func disconnectMCPClients(for profile: CDPProfile, completion: @escaping (Result<Int, Error>) -> Void) {
        Task {
            do {
                let clients = try CDPProcessInspector.attachedMCPClients(on: profile.port)
                guard !clients.isEmpty else {
                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.success(0))
                    }
                    return
                }

                CDPProcessInspector.terminateMCPClients(processIDs: clients.map(\.processID))
                try? await Task.sleep(for: .milliseconds(200))

                let remainingClients = try CDPProcessInspector.attachedMCPClients(on: profile.port)

                await MainActor.run {
                    self.refreshStatuses()

                    if remainingClients.isEmpty {
                        completion(.success(clients.count))
                    } else {
                        completion(.failure(LauncherError.mcpClientsStillConnected(profile.port)))
                    }
                }
            } catch {
                await MainActor.run {
                    self.refreshStatuses()
                    completion(.failure(error))
                }
            }
        }
    }

    private func cleanLocks(for profile: CDPProfile) {
        let root = profile.expandedProfileRoot
        let profileDir = (root as NSString).appendingPathComponent(profile.profileDirectory)
        let lockPaths = [
            "SingletonLock",
            "SingletonSocket",
            "SingletonCookie",
        ]

        for name in lockPaths {
            try? fileManager.removeItem(atPath: (root as NSString).appendingPathComponent(name))
            try? fileManager.removeItem(atPath: (profileDir as NSString).appendingPathComponent(name))
        }
    }

    private func launchBrowser(for profile: CDPProfile, initialURL: URL?) throws {
        try ensureDownloadPreferences(for: profile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        var arguments = [
            "-na", profile.browserAppName,
            "--args",
            "--user-data-dir=\(profile.expandedProfileRoot)",
            "--profile-directory=\(profile.profileDirectory)",
            "--remote-debugging-port=\(profile.port)",
            "--remote-allow-origins=*",
            "--no-first-run",
            "--disable-features=DevToolsDebuggingRestrictions",
        ]

        if let initialURL {
            arguments.append(initialURL.absoluteString)
        } else if let defaultURL = profile.defaultURL {
            arguments.append(defaultURL)
        }

        process.arguments = arguments
        try process.run()
    }

    private func ensureDownloadPreferences(for profile: CDPProfile) throws {
        let preferencesURL = URL(fileURLWithPath: profile.preferencesPath)
        try fileManager.createDirectory(
            at: preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let preferences = try Self.readPreferences(at: preferencesURL)
        let updatedPreferences = Self.preferencesWithDownloadDirectory(
            preferences,
            downloadDirectory: profile.expandedDownloadDirectory
        )
        let data = try JSONSerialization.data(
            withJSONObject: updatedPreferences,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        try data.write(to: preferencesURL, options: .atomic)
    }

    static func preferencesWithDownloadDirectory(
        _ preferences: [String: Any],
        downloadDirectory: String
    ) -> [String: Any] {
        var updatedPreferences = preferences

        var download = preferences["download"] as? [String: Any] ?? [:]
        download["default_directory"] = downloadDirectory
        download["directory_upgrade"] = true
        download["prompt_for_download"] = false
        updatedPreferences["download"] = download

        var savefile = preferences["savefile"] as? [String: Any] ?? [:]
        savefile["default_directory"] = downloadDirectory
        updatedPreferences["savefile"] = savefile

        return updatedPreferences
    }

    private static func readPreferences(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return [:]
        }

        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func newTabEndpoint(for url: URL, port: Int) -> URL {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? url.absoluteString
        return URL(string: "http://127.0.0.1:\(port)/json/new?\(encodedURL)")!
    }

    private static func checkEndpoint(_ endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 0.8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            return String(data: data, encoding: .utf8)?.contains("webSocketDebuggerUrl") == true
        } catch {
            return false
        }
    }

    private static func waitForEndpoint(_ endpoint: URL) async -> Bool {
        for _ in 0..<8 {
            if await checkEndpoint(endpoint) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private static func waitForEndpointToStop(_ endpoint: URL) async -> Bool {
        for _ in 0..<5 {
            if await !checkEndpoint(endpoint) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func openNewTab(_ url: URL, port: Int) async throws {
        var request = URLRequest(url: newTabEndpoint(for: url, port: port))
        request.httpMethod = "PUT"
        request.timeoutInterval = 4

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            throw LauncherError.openTabFailed(url: url, port: port, statusCode: statusCode)
        }
    }

}

enum LauncherError: LocalizedError {
    case endpointDidNotRespond(Int)
    case endpointStillResponding(Int)
    case openTabFailed(url: URL, port: Int, statusCode: Int?)
    case processLookupFailed(Int)
    case processTerminationFailed
    case mcpClientLookupFailed(Int?)
    case mcpClientsStillConnected(Int)

    var errorDescription: String? {
        switch self {
        case .endpointDidNotRespond(let port):
            "Helium opened, but CDP port \(port) did not respond."
        case .endpointStillResponding(let port):
            "Browser on CDP port \(port) did not close."
        case .openTabFailed(let url, let port, let statusCode):
            if let statusCode {
                "Could not open \(url.absoluteString) on CDP port \(port). DevTools returned \(statusCode)."
            } else {
                "Could not open \(url.absoluteString) on CDP port \(port)."
            }
        case .processLookupFailed(let port):
            "Could not find the browser process on CDP port \(port)."
        case .processTerminationFailed:
            "Could not close the browser process."
        case .mcpClientLookupFailed(let port):
            if let port {
                "Could not inspect MCP clients on CDP port \(port)."
            } else {
                "Could not inspect MCP client process details."
            }
        case .mcpClientsStillConnected(let port):
            "Some MCP clients are still connected to CDP port \(port)."
        }
    }
}
