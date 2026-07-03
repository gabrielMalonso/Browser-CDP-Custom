import AppKit
import Foundation

struct CDPProfile: Identifiable, Hashable {
    enum Kind: String {
        case personal
        case clinic
        case finance
    }

    let id: String
    let name: String
    let profileRoot: String
    let profileDirectory: String
    let browserAppName: String
    let port: Int
    let defaultURL: String?
    let kind: Kind

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(port)/json/version")!
    }

    var expandedProfileRoot: String {
        NSString(string: profileRoot).expandingTildeInPath
    }

    var preferencesPath: String {
        let profilePath = (expandedProfileRoot as NSString).appendingPathComponent(profileDirectory)
        return (profilePath as NSString).appendingPathComponent("Preferences")
    }

    var expandedDownloadDirectory: String {
        NSString(string: Self.downloadDirectory).expandingTildeInPath
    }

    var symbolName: String {
        switch kind {
        case .personal:
            "person.crop.circle"
        case .clinic:
            "cross.case"
        case .finance:
            "creditcard"
        }
    }

    var badgeText: String {
        switch id {
        case "central-es":
            "ES"
        case "central-rj":
            "RJ"
        case "central-sp":
            "SP"
        case "financeiro-rossoni":
            "F"
        case "financeiro-centralsp":
            "SP"
        case "pessoal":
            "P"
        default:
            String(name.prefix(1))
        }
    }

    static let downloadDirectory = "~/Downloads"

    static let visibleProfiles: [CDPProfile] = [
        CDPProfile(
            id: "pessoal",
            name: "Pessoal",
            profileRoot: "~/.chrome-cdp/pessoal",
            profileDirectory: "Default",
            browserAppName: "Google Chrome",
            port: 9224,
            defaultURL: nil,
            kind: .personal
        ),
        CDPProfile(
            id: "central-es",
            name: "Central ES",
            profileRoot: "~/.chrome-cdp/central-es",
            profileDirectory: "Default",
            browserAppName: "Helium",
            port: 9222,
            defaultURL: "https://web.whatsapp.com/",
            kind: .clinic
        ),
        CDPProfile(
            id: "central-rj",
            name: "Central RJ",
            profileRoot: "~/.chrome-cdp/central-rj",
            profileDirectory: "Default",
            browserAppName: "Helium",
            port: 9223,
            defaultURL: "https://web.whatsapp.com/",
            kind: .clinic
        ),
        CDPProfile(
            id: "financeiro-centralsp",
            name: "Financeiro/CentralSP",
            profileRoot: "~/.chrome-cdp/financeiro-centralsp-helium",
            profileDirectory: "Profile 1",
            browserAppName: "Helium",
            port: 9226,
            defaultURL: "https://web.whatsapp.com/",
            kind: .finance
        ),
    ]

    static var defaultProfile: CDPProfile {
        visibleProfiles[0]
    }

    static func profile(withID id: String?) -> CDPProfile {
        guard let id else {
            return defaultProfile
        }

        let normalizedID = legacyProfileIDAliases[id] ?? id
        return visibleProfiles.first { $0.id == normalizedID } ?? defaultProfile
    }

    private static let legacyProfileIDAliases = [
        "central-sp": "financeiro-centralsp",
        "financeiro-rossoni": "financeiro-centralsp",
    ]
}
