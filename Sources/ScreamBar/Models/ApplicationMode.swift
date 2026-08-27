import Foundation

enum ApplicationMode: String, Codable, CaseIterable, Sendable {
    case scream
    case directRouting

    var label: String {
        switch self {
        case .scream:
            return "Scream"
        case .directRouting:
            return "Direct Routing"
        }
    }
}
