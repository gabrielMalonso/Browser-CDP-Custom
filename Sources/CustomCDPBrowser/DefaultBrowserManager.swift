import AppKit
import CoreServices
import Foundation

enum DefaultBrowserManager {
    static func currentDefaultBrowserID() -> String? {
        defaultBrowserBundleID(for: "http")
    }

    static func isSelfDefaultBrowser() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        return defaultBrowserBundleID(for: "http") == bundleIdentifier
            && defaultBrowserBundleID(for: "https") == bundleIdentifier
    }

    static func setSelfAsDefaultBrowser(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            completion(.failure(DefaultBrowserError.missingBundleIdentifier))
            return
        }

        for scheme in ["http", "https"] {
            let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
            guard status == noErr else {
                completion(.failure(DefaultBrowserError.setFailed(scheme: scheme, status: status)))
                return
            }
        }

        completion(.success(()))
    }

    static func currentDefaultBrowserName() -> String {
        guard let bundleIdentifier = currentDefaultBrowserID() else {
            return "Unknown"
        }

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return "Custom CDP Browser"
        }

        guard
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
            let bundle = Bundle(url: appURL)
        else {
            return bundleIdentifier
        }

        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleIdentifier
    }

    private static func defaultBrowserBundleID(for scheme: String) -> String? {
        guard
            let url = URL(string: "\(scheme)://example.com"),
            let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
            let bundle = Bundle(url: appURL)
        else {
            return nil
        }

        return bundle.bundleIdentifier
    }
}

enum DefaultBrowserError: LocalizedError {
    case missingBundleIdentifier
    case setFailed(scheme: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            "The app bundle identifier is not available. Try this from the packaged .app."
        case .setFailed(let scheme, let status):
            "Could not set \(scheme) links as default. LaunchServices returned \(status)."
        }
    }
}
