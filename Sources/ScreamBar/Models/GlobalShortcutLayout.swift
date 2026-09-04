import Foundation

/// Defines whether audio and Wake-on-LAN share one shortcut or use two.
enum GlobalShortcutLayout: String, Codable, CaseIterable, Sendable {
    case combined
    case separate

    var label: String {
        switch self {
        case .combined:
            return "Combined"
        case .separate:
            return "Separate"
        }
    }

    var primaryAction: GlobalShortcutAction {
        switch self {
        case .combined:
            return .audioAndWakeOnLAN
        case .separate:
            return .audio
        }
    }

    var wakeOnLANAction: GlobalShortcutAction? {
        self == .separate ? .wakeOnLAN : nil
    }
}

enum GlobalShortcutAction: Equatable, Sendable {
    case audio
    case wakeOnLAN
    case audioAndWakeOnLAN
}
