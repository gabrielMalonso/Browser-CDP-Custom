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
        do {
            cleanLocks(for: profile)
            try launchHelium(for: profile)

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

    private func launchHelium(for profile: CDPProfile) throws {
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

        if let defaultURL = profile.defaultURL {
            arguments.append(defaultURL)
        }

        process.arguments = arguments
        try process.run()
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
    case processLookupFailed(Int)
    case processTerminationFailed

    var errorDescription: String? {
        switch self {
        case .endpointDidNotRespond(let port):
            "Helium opened, but CDP port \(port) did not respond."
        case .endpointStillResponding(let port):
            "Browser on CDP port \(port) did not close."
        case .processLookupFailed(let port):
            "Could not find the browser process on CDP port \(port)."
        case .processTerminationFailed:
            "Could not close the browser process."
        }
    }
}
