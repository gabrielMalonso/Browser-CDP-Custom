enum LinkRoutingMode: String, CaseIterable {
    case askEveryTime
    case personal
    case lastSelected

    init(storedValue: String?) {
        self = LinkRoutingMode(rawValue: storedValue ?? "") ?? .askEveryTime
    }

    var displayName: String {
        switch self {
        case .askEveryTime:
            "Always Ask"
        case .personal:
            "Pessoal"
        case .lastSelected:
            "Last Selected"
        }
    }
}
