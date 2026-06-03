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
}

enum LauncherError: LocalizedError {
    case endpointDidNotRespond(Int)

    var errorDescription: String? {
        switch self {
        case .endpointDidNotRespond(let port):
            "Helium opened, but CDP port \(port) did not respond."
        }
    }
}
