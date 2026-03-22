import Foundation

enum ProcessStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .error(let message): return "Error: \(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .starting: return true
        default: return false
        }
    }
}
