import Foundation

enum DirectRoutingAutomaticSensitivity: String, Codable, CaseIterable, Sendable {
    case strict
    case relaxed

    var label: String {
        switch self {
        case .strict:
            return "Strict"
        case .relaxed:
            return "Relaxed"
        }
    }

    var helpText: String {
        switch self {
        case .strict:
            return "Increases the automatic buffer after the first actionable runtime incident."
        case .relaxed:
            return "Tolerates up to 3 incidents in 10 seconds, then increases the automatic buffer."
        }
    }
}
