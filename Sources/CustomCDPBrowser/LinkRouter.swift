import Foundation

enum LinkRoutingDecision: Equatable {
    case ask
    case route(CDPProfile)
}

@MainActor
final class LinkRouter: ObservableObject {
    static let shared = LinkRouter()

    @Published private(set) var pendingURLs: [URL] = []
    @Published var feedback: String?

    var onShowOverlay: (() -> Void)?

    private let launcher: CDPProfileLauncher
    private let userDefaults: UserDefaults

    init(
        launcher: CDPProfileLauncher? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.launcher = launcher ?? .shared
        self.userDefaults = userDefaults
    }

    func handleIncomingURL(_ url: URL) {
        let mode = LinkRoutingMode(storedValue: userDefaults.string(forKey: UserDefaultsKeys.linkRoutingMode))
        let lastSelectedProfileID = userDefaults.string(forKey: UserDefaultsKeys.lastSelectedProfileID)

        switch Self.routingDecision(mode: mode, lastSelectedProfileID: lastSelectedProfileID) {
        case .ask:
            pendingURLs.append(url)
            feedback = nil
            onShowOverlay?()
        case .route(let profile):
            route([url], to: profile) { [weak self] result in
                guard let self else { return }

                if case .failure(let error) = result {
                    pendingURLs.append(url)
                    feedback = error.localizedDescription
                    onShowOverlay?()
                }
            }
        }
    }

    func routePendingURLs(to profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        let urls = pendingURLs
        pendingURLs.removeAll()
        feedback = nil

        routeKeepingRemainder(urls, to: profile) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                completion(.success(()))
            case .failure(let failure):
                pendingURLs.insert(contentsOf: failure.remainingURLs, at: 0)
                feedback = failure.error.localizedDescription
                completion(.failure(failure.error))
            }
        }
    }

    func route(_ urls: [URL], to profile: CDPProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        userDefaults.set(profile.id, forKey: UserDefaultsKeys.lastSelectedProfileID)

        routeKeepingRemainder(urls, to: profile) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let failure):
                completion(.failure(failure.error))
            }
        }
    }

    func cancelPendingURLs() {
        pendingURLs.removeAll()
        feedback = nil
    }

    static func routingDecision(mode: LinkRoutingMode, lastSelectedProfileID: String?) -> LinkRoutingDecision {
        switch mode {
        case .askEveryTime:
            .ask
        case .personal:
            .route(CDPProfile.defaultProfile)
        case .lastSelected:
            .route(CDPProfile.profile(withID: lastSelectedProfileID))
        }
    }

    private func routeKeepingRemainder(
        _ urls: [URL],
        to profile: CDPProfile,
        completion: @escaping (Result<Void, LinkRoutingFailure>) -> Void
    ) {
        guard !urls.isEmpty else {
            completion(.success(()))
            return
        }

        route(urls, to: profile, index: urls.startIndex, completion: completion)
    }

    private func route(
        _ urls: [URL],
        to profile: CDPProfile,
        index: Array<URL>.Index,
        completion: @escaping (Result<Void, LinkRoutingFailure>) -> Void
    ) {
        guard index < urls.endIndex else {
            completion(.success(()))
            return
        }

        launcher.openURL(urls[index], in: profile) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                route(urls, to: profile, index: urls.index(after: index), completion: completion)
            case .failure(let error):
                completion(.failure(LinkRoutingFailure(error: error, remainingURLs: Array(urls[index...]))))
            }
        }
    }
}

struct LinkRoutingFailure: Error {
    let error: Error
    let remainingURLs: [URL]
}

enum UserDefaultsKeys {
    static let linkRoutingMode = "linkRoutingMode"
    static let lastSelectedProfileID = "lastSelectedProfileID"
    static let mcpAutoCleanupEnabled = "mcpAutoCleanupEnabled"
}
