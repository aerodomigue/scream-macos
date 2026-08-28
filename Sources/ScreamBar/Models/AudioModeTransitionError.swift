import Foundation

enum AudioModeTransitionError: LocalizedError, Equatable {
    case cleanupFailed(mode: ApplicationMode, diagnostics: String)
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case .cleanupFailed(let mode, _):
            return "Could not stop \(mode.label); the next audio mode was not started"
        case .shuttingDown:
            return "Audio services are shutting down"
        }
    }
}
