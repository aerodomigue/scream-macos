import Foundation

/// Selects which application features an external trigger controls.
enum AutomationActionTarget: String, Codable, CaseIterable, Sendable {
    case audio
    case wakeOnLAN
    case audioAndWakeOnLAN

    var label: String {
        switch self {
        case .audio:
            return "Audio"
        case .wakeOnLAN:
            return "Wake on LAN"
        case .audioAndWakeOnLAN:
            return "Audio + Wake on LAN"
        }
    }

    var includesAudio: Bool {
        self != .wakeOnLAN
    }

    var includesWakeOnLAN: Bool {
        self != .audio
    }
}
