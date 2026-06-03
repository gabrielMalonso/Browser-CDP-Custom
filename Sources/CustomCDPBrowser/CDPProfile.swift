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
        case "pessoal":
            "P"
        default:
            String(name.prefix(1))
        }
    }

    static let visibleProfiles: [CDPProfile] = [
        CDPProfile(
            id: "pessoal",
            name: "Pessoal",
            profileRoot: "~/.chrome-cdp/pessoal",
            profileDirectory: "Default",
            browserAppName: "Helium",
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
            id: "central-sp",
            name: "Central SP",
            profileRoot: "~/.chrome-cdp/central-sp",
            profileDirectory: "Default",
            browserAppName: "Helium",
            port: 9225,
            defaultURL: "https://web.whatsapp.com/",
            kind: .clinic
        ),
        CDPProfile(
            id: "financeiro-rossoni",
            name: "Financeiro Rossoni",
            profileRoot: "~/.chrome-cdp/financeiro-rossoni",
            profileDirectory: "Profile 12",
            browserAppName: "Google Chrome",
            port: 9226,
            defaultURL: "https://mail.google.com/mail/u/0/#inbox",
            kind: .finance
        ),
    ]

    static var defaultProfile: CDPProfile {
        visibleProfiles[0]
    }

    static func profile(withID id: String?) -> CDPProfile {
        guard let id, let profile = visibleProfiles.first(where: { $0.id == id }) else {
            return defaultProfile
        }

        return profile
    }
}
