import AppKit
import Foundation

struct CDPAttachedClient: Equatable, Hashable {
    let processID: String
    let command: String
    let residentMemoryKilobytes: Int

    init(processID: String, command: String, residentMemoryKilobytes: Int = 0) {
        self.processID = processID
        self.command = command
        self.residentMemoryKilobytes = residentMemoryKilobytes
    }
}

enum CDPProcessInspector {
    struct ProcessSnapshot: Equatable {
        let processID: String
        let parentProcessID: String
        let residentMemoryKilobytes: Int
        let command: String

        init(
            processID: String,
            parentProcessID: String = "",
            residentMemoryKilobytes: Int,
            command: String
        ) {
            self.processID = processID
            self.parentProcessID = parentProcessID
            self.residentMemoryKilobytes = residentMemoryKilobytes
            self.command = command
        }
    }

    struct MCPProcess: Equatable {
        let processID: String
        let parentProcessID: String
        let port: Int
        let residentMemoryKilobytes: Int
        let command: String
    }

    static func establishedLsofArguments(for port: Int) -> [String] {
        ["-nP", "-tiTCP:\(port)", "-sTCP:ESTABLISHED"]
    }

    static func processListArguments() -> [String] {
        ["-axo", "pid=,ppid=,rss=,command="]
    }

    static func uniqueProcessIDs(from output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func isPlaywrightMCPCommand(_ command: String, for port: Int) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.contains(where: { $0 == "playwright-mcp" || $0.hasSuffix("/playwright-mcp") }) else {
            return false
        }
        return hasMatchingCDPEndpoint(in: tokens, for: port)
    }

    static func isPlaywrightMCPProcessCommand(_ command: String, for port: Int) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let isClient = tokens.contains(where: { $0 == "playwright-mcp" || $0.hasSuffix("/playwright-mcp") })
        let isRunner = tokens.contains(where: { $0 == "@playwright/mcp" || $0.hasPrefix("@playwright/mcp@") })
        return (isClient || isRunner) && hasMatchingCDPEndpoint(in: tokens, for: port)
    }

    static func isMainGoogleChromeCommand(_ command: String) -> Bool {
        command.contains("/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    static func isNormalGoogleChromeCommand(_ command: String) -> Bool {
        isMainGoogleChromeCommand(command) && !command.contains("--user-data-dir")
    }

    static func processCommands(from output: String) -> [String: String] {
        var commandsByProcessID: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let processID = String(trimmed[..<separator])
            let command = String(trimmed[separator...]).trimmingCharacters(in: .whitespaces)
            guard !processID.isEmpty, !command.isEmpty else { continue }
            commandsByProcessID[processID] = command
        }
        return commandsByProcessID
    }

    static func processSnapshots(from output: String) -> [ProcessSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let pidEnd = line.firstIndex(where: \.isWhitespace) else { return nil }
            let pid = String(line[..<pidEnd])
            let afterPID = line[pidEnd...].trimmingCharacters(in: .whitespaces)
            guard let ppidEnd = afterPID.firstIndex(where: \.isWhitespace) else { return nil }
            let ppid = String(afterPID[..<ppidEnd])
            let afterPPID = afterPID[ppidEnd...].trimmingCharacters(in: .whitespaces)
            guard let rssEnd = afterPPID.firstIndex(where: \.isWhitespace) else { return nil }
            let rss = Int(afterPPID[..<rssEnd]) ?? 0
            let command = afterPPID[rssEnd...].trimmingCharacters(in: .whitespaces)
            guard !pid.isEmpty, !command.isEmpty else { return nil }
            return ProcessSnapshot(
                processID: pid,
                parentProcessID: ppid,
                residentMemoryKilobytes: rss,
                command: String(command)
            )
        }
    }

    static func clients(from commandsByProcessID: [String: String], port: Int) -> [CDPAttachedClient] {
        commandsByProcessID
            .filter { isPlaywrightMCPCommand($0.value, for: port) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { CDPAttachedClient(processID: $0.key, command: $0.value) }
    }

    static func clients(from snapshots: [ProcessSnapshot], port: Int) -> [CDPAttachedClient] {
        snapshots
            .filter { isPlaywrightMCPCommand($0.command, for: port) }
            .sorted { $0.processID.localizedStandardCompare($1.processID) == .orderedAscending }
            .map {
                CDPAttachedClient(
                    processID: $0.processID,
                    command: $0.command,
                    residentMemoryKilobytes: $0.residentMemoryKilobytes
                )
            }
    }

    static func mcpResidentMemoryKilobytes(from snapshots: [ProcessSnapshot], ports: [Int]) -> Int {
        mcpProcesses(from: snapshots, ports: ports).reduce(0) { $0 + $1.residentMemoryKilobytes }
    }

    static func mcpProcesses(from snapshots: [ProcessSnapshot], ports: [Int]) -> [MCPProcess] {
        snapshots.flatMap { snapshot in
            ports.compactMap { port in
                guard isPlaywrightMCPProcessCommand(snapshot.command, for: port) else { return nil }
                return MCPProcess(
                    processID: snapshot.processID,
                    parentProcessID: snapshot.parentProcessID,
                    port: port,
                    residentMemoryKilobytes: snapshot.residentMemoryKilobytes,
                    command: snapshot.command
                )
            }
        }
    }

    static func normalGoogleChromeProcessIDs(from snapshots: [ProcessSnapshot]) -> [String] {
        snapshots
            .filter { isNormalGoogleChromeCommand($0.command) }
            .sorted { $0.processID.localizedStandardCompare($1.processID) == .orderedAscending }
            .map(\.processID)
    }

    static func idleMCPProcesses(
        from processes: [MCPProcess],
        listeningPorts: Set<Int>,
        establishedProcessIDsByPort: [Int: Set<String>]
    ) -> [MCPProcess] {
        processes.filter { process in
            guard listeningPorts.contains(process.port) else { return true }
            let established = establishedProcessIDsByPort[process.port] ?? []
            return !established.contains(process.processID) && !processes.contains {
                $0.parentProcessID == process.processID
                    && $0.port == process.port
                    && established.contains($0.processID)
            }
        }
    }

    static func normalGoogleChromeProcessIDs() throws -> [String] {
        normalGoogleChromeProcessIDs(from: try processSnapshots())
    }

    private static func hasMatchingCDPEndpoint(in tokens: [String], for port: Int) -> Bool {
        let endpoints = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
        for index in tokens.indices where tokens[index] == "--cdp-endpoint" {
            let next = tokens.index(after: index)
            if next < tokens.endIndex, endpoints.contains(tokens[next]) { return true }
        }
        return endpoints.contains { tokens.contains("--cdp-endpoint=\($0)") }
    }

    private static func processSnapshots() throws -> [ProcessSnapshot] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = processListArguments()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LauncherError.processLookupFailed }
        return processSnapshots(from: String(data: data, encoding: .utf8) ?? "")
    }
}

@MainActor
final class CDPProfileLauncher: ObservableObject {
    static let shared = CDPProfileLauncher()

    @Published private(set) var runningProfileIDs: Set<String> = []
    @Published private(set) var profileStateByID: [String: String] = [:]
    @Published private(set) var profileDetailByID: [String: String] = [:]
    @Published private(set) var mcpClientsByProfileID: [String: [CDPAttachedClient]] = [:]
    @Published private(set) var gatewayAvailable = false
    @Published private(set) var mcpAutoCleanupFeedback: String?

    private let gateway = MCPGatewayClient()
    private var refreshGeneration = 0

    func refreshStatuses() {
        refreshGeneration += 1
        let generation = refreshGeneration

        Task {
            do {
                let statuses = try await gateway.profiles()
                guard refreshGeneration == generation else { return }
                runningProfileIDs = Set(statuses.filter { $0.browser.state == "ready" }.map(\.id))
                profileStateByID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0.browser.state) })
                profileDetailByID = Dictionary(
                    uniqueKeysWithValues: statuses.compactMap { status in
                        status.browser.detail.map { (status.id, $0) }
                    }
                )
                mcpClientsByProfileID = Dictionary(
                    uniqueKeysWithValues: statuses.compactMap { status in
                        guard let pid = status.worker?.pid else { return nil }
                        return (
                            status.id,
                            [CDPAttachedClient(processID: String(pid), command: "Worker lazy gerenciado pelo supervisor")]
                        )
                    }
                )
                gatewayAvailable = true
            } catch {
                guard refreshGeneration == generation else { return }
                gatewayAvailable = false
                mcpAutoCleanupFeedback = error.localizedDescription
            }
        }
    }

    func open(_ profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        ensureRunning(profile, initialURL: nil, completion: completion)
    }

    func ensureRunning(_ profile: CDPProfile, initialURL: URL?, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                if let targetURL = initialURL ?? profile.defaultURL.flatMap(URL.init(string:)) {
                    try await gateway.openURL(targetURL, in: profile)
                } else {
                    try await gateway.start(profile: profile)
                }
                refreshStatuses()
                completion(.success(()))
            } catch {
                refreshStatuses()
                completion(.failure(error))
            }
        }
    }

    func openURL(_ url: URL, in profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await gateway.openURL(url, in: profile)
                refreshStatuses()
                completion(.success(()))
            } catch {
                refreshStatuses()
                completion(.failure(error))
            }
        }
    }

    func close(_ profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                _ = try await gateway.stop(profile: profile)
                refreshStatuses()
                completion(.success(()))
            } catch {
                refreshStatuses()
                completion(.failure(error))
            }
        }
    }

    func closeAllControlledBrowsers(completion: @escaping (Result<Int, Error>) -> Void) {
        Task {
            do {
                var closed = 0
                for profile in CDPProfile.visibleProfiles {
                    if try await gateway.stop(profile: profile) { closed += 1 }
                }
                refreshStatuses()
                completion(.success(closed))
            } catch {
                refreshStatuses()
                completion(.failure(error))
            }
        }
    }

    func disconnectMCPClients(for profile: CDPProfile, completion: @escaping (Result<Int, Error>) -> Void) {
        Task {
            do {
                let released = try await gateway.release(profile: profile)
                refreshStatuses()
                completion(.success(released ? 1 : 0))
            } catch {
                refreshStatuses()
                completion(.failure(error))
            }
        }
    }

    func runAutoCleanupNow(completion: ((Result<Int, Error>) -> Void)? = nil) {
        Task {
            do {
                var released = 0
                for profile in CDPProfile.visibleProfiles where try await gateway.release(profile: profile) {
                    released += 1
                }
                mcpAutoCleanupFeedback = "Workers ociosos liberados pelo supervisor."
                refreshStatuses()
                completion?(.success(released))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    func openNormalGoogleChrome(completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                if let processID = try CDPProcessInspector.normalGoogleChromeProcessIDs().first,
                   let pid = pid_t(processID),
                   let app = NSRunningApplication(processIdentifier: pid)
                {
                    app.activate(options: [.activateAllWindows])
                    completion(.success(()))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", "-a", "Google Chrome"]
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw LauncherError.normalChromeOpenFailed }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

enum LauncherError: LocalizedError {
    case processLookupFailed
    case normalChromeOpenFailed

    var errorDescription: String? {
        switch self {
        case .processLookupFailed:
            "Não foi possível inspecionar os processos do Google Chrome."
        case .normalChromeOpenFailed:
            "Não foi possível abrir o Google Chrome normal."
        }
    }
}
