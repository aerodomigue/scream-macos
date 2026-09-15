import Foundation

enum ApplicationMode: String, Codable, CaseIterable, Sendable {
    case off
    case scream
    case directRouting
    case steelSeriesOmni

    var routesAudio: Bool { self == .scream || self == .directRouting }

    var label: String {
        switch self {
        case .off:
            return "OFF"
        case .scream:
            return "Scream"
        case .directRouting:
            return "Direct Routing"
        case .steelSeriesOmni:
            return "SteelSeries Omni"
        }
    }
}
