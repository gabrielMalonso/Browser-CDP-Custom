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

        return hasMatchingCDPEndpoint(in: tokens, for: port)
    }

    static func isPlaywrightMCPProcessCommand(_ command: String, for port: Int) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let isMCPClient = tokens.contains(where: { $0 == "playwright-mcp" || $0.hasSuffix("/playwright-mcp") })
        let isMCPRunner = tokens.contains(where: { $0 == "@playwright/mcp" || $0.hasPrefix("@playwright/mcp@") })
        guard isMCPClient || isMCPRunner else { return false }

        return hasMatchingCDPEndpoint(in: tokens, for: port)
    }

    static func isMainGoogleChromeCommand(_ command: String) -> Bool {
        command.contains("/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    static func isNormalGoogleChromeCommand(_ command: String) -> Bool {
        isMainGoogleChromeCommand(command) && !command.contains("--user-data-dir")
    }

    private static func hasMatchingCDPEndpoint(in tokens: [String], for port: Int) -> Bool {
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

    static func processSnapshots(from output: String) -> [ProcessSnapshot] {
        var snapshots: [ProcessSnapshot] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard let processIDEnd = trimmedLine.firstIndex(where: \.isWhitespace) else { continue }

            let processID = String(trimmedLine[..<processIDEnd])
            let remainder = trimmedLine[processIDEnd...].trimmingCharacters(in: .whitespaces)
            guard let parentProcessIDEnd = remainder.firstIndex(where: \.isWhitespace) else { continue }

            let parentProcessID = String(remainder[..<parentProcessIDEnd])
            let memoryAndCommand = remainder[parentProcessIDEnd...].trimmingCharacters(in: .whitespaces)
            guard let rssEnd = memoryAndCommand.firstIndex(where: \.isWhitespace) else { continue }

            let rss = Int(memoryAndCommand[..<rssEnd]) ?? 0
            let command = memoryAndCommand[rssEnd...].trimmingCharacters(in: .whitespaces)
            guard !processID.isEmpty, !command.isEmpty else { continue }

            snapshots.append(
                ProcessSnapshot(
                    processID: processID,
                    parentProcessID: parentProcessID,
                    residentMemoryKilobytes: rss,
                    command: String(command)
                )
            )
        }

        return snapshots
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
        mcpProcesses(from: snapshots, ports: ports)
            .reduce(0) { $0 + $1.residentMemoryKilobytes }
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

            let establishedProcessIDs = establishedProcessIDsByPort[process.port] ?? []
            let hasEstablishedConnection = establishedProcessIDs.contains(process.processID)
            let hasEstablishedChild = processes.contains { candidate in
                candidate.parentProcessID == process.processID
                    && candidate.port == process.port
                    && establishedProcessIDs.contains(candidate.processID)
            }

            return !hasEstablishedConnection && !hasEstablishedChild
        }
    }

    static func attachedMCPClients(on port: Int) throws -> [CDPAttachedClient] {
        try clients(from: processSnapshots(), port: port)
    }

    static func attachedMCPClientsByPort(_ ports: [Int]) throws -> [Int: [CDPAttachedClient]] {
        let snapshots = try processSnapshots()
        return Dictionary(uniqueKeysWithValues: ports.map { port in
            (port, clients(from: snapshots, port: port))
        })
    }

    static func mcpResidentMemoryKilobytes(on ports: [Int]) throws -> Int {
        try mcpResidentMemoryKilobytes(from: processSnapshots(), ports: ports)
    }

    static func mcpProcesses(on ports: [Int]) throws -> [MCPProcess] {
        try mcpProcesses(from: processSnapshots(), ports: ports)
    }

    static func normalGoogleChromeProcessIDs() throws -> [String] {
        try normalGoogleChromeProcessIDs(from: processSnapshots())
    }

    static func idleMCPProcesses(on ports: [Int]) throws -> [MCPProcess] {
        let snapshots = try processSnapshots()
        let processes = mcpProcesses(from: snapshots, ports: ports)
        var listeningPorts = Set<Int>()
        var establishedProcessIDsByPort: [Int: Set<String>] = [:]

        for port in ports {
            if !(try processIDsListening(on: port)).isEmpty {
                listeningPorts.insert(port)
            }
            establishedProcessIDsByPort[port] = Set(try processIDsWithEstablishedConnections(on: port))
        }

        return idleMCPProcesses(
            from: processes,
            listeningPorts: listeningPorts,
            establishedProcessIDsByPort: establishedProcessIDsByPort
        )
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

    private static func processSnapshots() throws -> [ProcessSnapshot] {
        let output = try output(
            executablePath: "/bin/ps",
            arguments: processListArguments(),
            failure: LauncherError.mcpClientLookupFailed(nil)
        )

        return processSnapshots(from: output)
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
    static let mcpAutoCleanupIntervalSeconds: TimeInterval = 60
    static let mcpAutoCleanupMinimumIdleSeconds: TimeInterval = 300

    @Published private(set) var runningProfileIDs: Set<String> = []
    @Published private(set) var mcpClientsByProfileID: [String: [CDPAttachedClient]] = [:]
    @Published private(set) var mcpResidentMemoryKilobytes = 0
    @Published private(set) var mcpAutoCleanupFeedback: String?

    private let fileManager = FileManager.default
    private let mcpGatewayClient = MCPGatewayClient()
    private var refreshGeneration = 0
    private var autoCleanupTask: Task<Void, Never>?
    private var idleMCPFirstSeenAtByProcessID: [String: Date] = [:]

    func refreshStatuses() {
        refreshGeneration += 1
        let generation = refreshGeneration

        Task {
            var running = Set<String>()
            var mcpClientsByProfileID: [String: [CDPAttachedClient]] = [:]
            let visiblePorts = CDPProfile.visibleProfiles.map(\.port)
            let mcpClientsByPort = (try? CDPProcessInspector.attachedMCPClientsByPort(visiblePorts)) ?? [:]
            let mcpResidentMemoryKilobytes = (try? CDPProcessInspector.mcpResidentMemoryKilobytes(
                on: visiblePorts
            )) ?? 0

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
                self.mcpResidentMemoryKilobytes = mcpResidentMemoryKilobytes
            }
        }
    }

    func open(_ profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        ensureRunning(profile, initialURL: nil, completion: completion)
    }

    func ensureRunning(_ profile: CDPProfile, initialURL: URL?, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            cleanLocks(for: profile)
            try launchBrowser(for: profile)

            Task {
                let ok = await Self.waitForEndpoint(profile.endpoint)
                guard ok else {
                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.failure(LauncherError.endpointDidNotRespond(profile.port)))
                    }
                    return
                }

                await MainActor.run {
                    self.refreshStatuses()
                }

                if let startupURL = Self.startupURL(for: profile, initialURL: initialURL) {
                    do {
                        try await Self.openNewTab(startupURL, port: profile.port)
                    } catch {
                        await MainActor.run {
                            completion(.failure(error))
                        }
                        return
                    }
                }

                await MainActor.run {
                    self.refreshStatuses()
                    completion(.success(()))
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

    func closeAllControlledBrowsers(completion: @escaping (Result<Int, Error>) -> Void) {
        Task {
            do {
                var closedProfileCount = 0
                var profilesWithProcesses: [CDPProfile] = []

                for profile in CDPProfile.visibleProfiles {
                    let processIDs = try CDPProcessInspector.processIDsListening(on: profile.port)
                    guard !processIDs.isEmpty else { continue }

                    try CDPProcessInspector.terminate(processIDs: processIDs)
                    closedProfileCount += 1
                    profilesWithProcesses.append(profile)
                }

                var portsStillResponding: [Int] = []
                for profile in profilesWithProcesses {
                    let didClose = await Self.waitForEndpointToStop(profile.endpoint)
                    if !didClose {
                        portsStillResponding.append(profile.port)
                    }
                }

                await MainActor.run {
                    self.refreshStatuses()

                    if portsStillResponding.isEmpty {
                        completion(.success(closedProfileCount))
                    } else {
                        completion(.failure(LauncherError.endpointsStillResponding(portsStillResponding)))
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

    func openNormalGoogleChrome(completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                if let processID = try CDPProcessInspector.normalGoogleChromeProcessIDs().first,
                   let pid = pid_t(processID),
                   let app = NSRunningApplication(processIdentifier: pid)
                {
                    app.activate(options: [.activateAllWindows])
                    await MainActor.run {
                        completion(.success(()))
                    }
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", "-a", "Google Chrome"]
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    await MainActor.run {
                        completion(.failure(LauncherError.normalChromeOpenFailed))
                    }
                    return
                }

                await MainActor.run {
                    completion(.success(()))
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
                if await mcpGatewayClient.isHealthy() {
                    let released = try await mcpGatewayClient.release(profile: profile)
                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.success(released ? 1 : 0))
                    }
                    return
                }

                let processes = try CDPProcessInspector.mcpProcesses(on: [profile.port])
                guard !processes.isEmpty else {
                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.success(0))
                    }
                    return
                }

                CDPProcessInspector.terminateMCPClients(processIDs: processes.map(\.processID))
                try? await Task.sleep(for: .milliseconds(200))

                let remainingProcesses = try CDPProcessInspector.mcpProcesses(on: [profile.port])

                await MainActor.run {
                    self.refreshStatuses()

                    if remainingProcesses.isEmpty {
                        completion(.success(processes.count))
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

    func configureAutoCleanup() {
        let defaultEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.mcpAutoCleanupEnabled) as? Bool ?? false

        if defaultEnabled {
            startAutoCleanup()
        } else {
            stopAutoCleanup()
        }
    }

    func runAutoCleanupNow(completion: ((Result<Int, Error>) -> Void)? = nil) {
        Task {
            do {
                if await mcpGatewayClient.isHealthy() {
                    var releasedCount = 0
                    for profile in CDPProfile.visibleProfiles {
                        if try await mcpGatewayClient.release(profile: profile) {
                            releasedCount += 1
                        }
                    }
                    refreshStatuses()
                    mcpAutoCleanupFeedback = "Workers liberados com segurança pelo gateway."
                    completion?(.success(releasedCount))
                    return
                }

                let cleanedCount = try await runAutoCleanupCycle(now: Date(), cleanImmediately: true)
                completion?(.success(cleanedCount))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    private func startAutoCleanup() {
        guard autoCleanupTask == nil else { return }

        autoCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    _ = try await self?.runAutoCleanupCycle(now: Date(), cleanImmediately: false)
                } catch {
                    await MainActor.run {
                        self?.mcpAutoCleanupFeedback = "Falha ao limpar MCPs ociosos"
                    }
                }

                try? await Task.sleep(for: .seconds(Int(Self.mcpAutoCleanupIntervalSeconds)))
            }
        }
    }

    private func stopAutoCleanup() {
        autoCleanupTask?.cancel()
        autoCleanupTask = nil
        idleMCPFirstSeenAtByProcessID = [:]
    }

    private func runAutoCleanupCycle(now: Date, cleanImmediately: Bool) async throws -> Int {
        if await mcpGatewayClient.isHealthy() {
            mcpAutoCleanupFeedback = "Gateway MCP ativo; workers ociosos são liberados pelo daemon."
            refreshStatuses()
            return 0
        }

        let visiblePorts = CDPProfile.visibleProfiles.map(\.port)
        let idleProcesses = try CDPProcessInspector.idleMCPProcesses(on: visiblePorts)
        let idleProcessIDs = Set(idleProcesses.map(\.processID))

        idleMCPFirstSeenAtByProcessID = idleMCPFirstSeenAtByProcessID.filter { idleProcessIDs.contains($0.key) }

        for process in idleProcesses where idleMCPFirstSeenAtByProcessID[process.processID] == nil {
            idleMCPFirstSeenAtByProcessID[process.processID] = now
        }

        let expiredProcesses = idleProcesses.filter { process in
            if cleanImmediately {
                return true
            }
            guard let firstSeenAt = idleMCPFirstSeenAtByProcessID[process.processID] else { return false }
            return now.timeIntervalSince(firstSeenAt) >= Self.mcpAutoCleanupMinimumIdleSeconds
        }
        let expiredProcessIDs = Array(Set(expiredProcesses.map(\.processID))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        guard !expiredProcessIDs.isEmpty else {
            refreshStatuses()
            return 0
        }

        CDPProcessInspector.terminateMCPClients(processIDs: expiredProcessIDs)
        try? await Task.sleep(for: .milliseconds(200))

        for processID in expiredProcessIDs {
            idleMCPFirstSeenAtByProcessID.removeValue(forKey: processID)
        }

        refreshStatuses()
        mcpAutoCleanupFeedback = "Auto-limpeza liberou \(expiredProcessIDs.count) MCP\(expiredProcessIDs.count == 1 ? "" : "s") ocioso\(expiredProcessIDs.count == 1 ? "" : "s")"
        return expiredProcessIDs.count
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

    private func launchBrowser(for profile: CDPProfile) throws {
        try ensureDownloadPreferences(for: profile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        let arguments = [
            "-na", profile.browserAppName,
            "--args",
            "--user-data-dir=\(profile.expandedProfileRoot)",
            "--profile-directory=\(profile.profileDirectory)",
            "--remote-debugging-port=\(profile.port)",
            "--remote-allow-origins=*",
            "--no-first-run",
            "--disable-features=DevToolsDebuggingRestrictions",
        ]

        process.arguments = arguments
        try process.run()
    }

    static func startupURL(for profile: CDPProfile, initialURL: URL?) -> URL? {
        initialURL ?? profile.defaultURL.flatMap(URL.init(string:))
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
    case endpointsStillResponding([Int])
    case openTabFailed(url: URL, port: Int, statusCode: Int?)
    case processLookupFailed(Int)
    case processTerminationFailed
    case mcpClientLookupFailed(Int?)
    case mcpClientsStillConnected(Int)
    case normalChromeOpenFailed

    var errorDescription: String? {
        switch self {
        case .endpointDidNotRespond(let port):
            "Browser opened, but CDP port \(port) did not respond."
        case .endpointStillResponding(let port):
            "Browser on CDP port \(port) did not close."
        case .endpointsStillResponding(let ports):
            "Browsers on CDP ports \(ports.map(String.init).joined(separator: ", ")) did not close."
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
        case .normalChromeOpenFailed:
            "Could not open normal Google Chrome."
        }
    }
}
