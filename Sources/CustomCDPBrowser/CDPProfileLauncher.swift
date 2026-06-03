import Foundation

@MainActor
final class CDPProfileLauncher: ObservableObject {
    static let shared = CDPProfileLauncher()

    @Published private(set) var runningProfileIDs: Set<String> = []

    private let fileManager = FileManager.default

    func refreshStatuses() {
        Task {
            var running = Set<String>()

            await withTaskGroup(of: (String, Bool).self) { group in
                for profile in CDPProfile.visibleProfiles {
                    group.addTask {
                        let isRunning = await Self.checkEndpoint(profile.endpoint)
                        return (profile.id, isRunning)
                    }
                }

                for await (id, isRunning) in group where isRunning {
                    running.insert(id)
                }
            }

            await MainActor.run {
                self.runningProfileIDs = running
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
                let processIDs = try Self.processIDsListening(on: profile.port)
                guard !processIDs.isEmpty else {
                    await MainActor.run {
                        self.refreshStatuses()
                        completion(.success(()))
                    }
                    return
                }

                try Self.terminate(processIDs: processIDs)
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

    private static func processIDsListening(on port: Int) throws -> [String] {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 1 {
            return []
        }

        guard process.terminationStatus == 0 else {
            throw LauncherError.processLookupFailed(port)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
    }

    private static func terminate(processIDs: [String]) throws {
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = processIDs
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LauncherError.processTerminationFailed
        }
    }
}

enum LauncherError: LocalizedError {
    case endpointDidNotRespond(Int)
    case endpointStillResponding(Int)
    case openTabFailed(url: URL, port: Int, statusCode: Int?)
    case processLookupFailed(Int)
    case processTerminationFailed

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
        }
    }
}
