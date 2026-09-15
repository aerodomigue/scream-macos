import AppKit

enum MenuBarIndicatorState: Equatable {
    case inactive
    case active
    case unknown
    case problem

    var color: NSColor {
        switch self {
        case .inactive: return .systemGray
        case .active: return .systemGreen
        case .unknown: return .systemOrange
        case .problem: return .systemRed
        }
    }
}

struct MenuBarIndicator: Equatable {
    let mode: ApplicationMode
    let state: MenuBarIndicatorState

    var symbolName: String {
        guard mode.routesAudio else { return "macpro.gen3" }
        switch state {
        case .inactive: return "speaker.fill"
        case .active: return "speaker.wave.2.fill"
        case .unknown: return "speaker.wave.1.fill"
        case .problem: return "speaker.slash.fill"
        }
    }

    var description: String {
        if !mode.routesAudio {
            switch state {
            case .inactive: return "PC offline"
            case .active: return "PC online"
            case .unknown: return "PC status unknown"
            case .problem: return "PC monitoring or application error"
            }
        }
        switch state {
        case .inactive: return "Audio stopped"
        case .active: return "Audio running"
        case .unknown: return "Audio waiting or changing state"
        case .problem: return "Audio error"
        }
    }

    @MainActor
    var image: NSImage? {
        MenuBarSymbol.image(name: symbolName, color: state.color, description: description)
    }

    static func host(
        isEnabled: Bool,
        reachability: WakeOnLANReachability,
        agentIsReachable: Bool,
        hasError: Bool
    ) -> Self {
        let state: MenuBarIndicatorState
        if hasError {
            state = .problem
        } else if !isEnabled {
            state = .unknown
        } else if reachability == .online || agentIsReachable {
            state = .active
        } else if reachability == .offline {
            state = .inactive
        } else {
            state = .unknown
        }
        return Self(mode: .off, state: state)
    }

    static func audio(
        mode: ApplicationMode,
        routingState: AudioRoutingState,
        jackStatus: ProcessStatus,
        screamStatus: ProcessStatus,
        isTransitioning: Bool,
        hasTransitionError: Bool
    ) -> Self {
        if hasTransitionError { return Self(mode: mode, state: .problem) }
        if isTransitioning { return Self(mode: mode, state: .unknown) }
        let state: MenuBarIndicatorState
        switch mode {
        case .off, .steelSeriesOmni:
            state = .unknown
        case .directRouting:
            switch routingState {
            case .running: state = .active
            case .stopped: state = .inactive
            case .failed: state = .problem
            case .starting, .stopping, .reconfiguring, .waitingForInput, .waitingForOutput:
                state = .unknown
            }
        case .scream:
            if case .error = jackStatus {
                state = .problem
            } else if case .error = screamStatus {
                state = .problem
            } else if jackStatus == .running && screamStatus == .running {
                state = .active
            } else if jackStatus == .stopped && screamStatus == .stopped {
                state = .inactive
            } else {
                state = .unknown
            }
        }
        return Self(mode: mode, state: state)
    }

    static func needsHostMonitoring(mode: ApplicationMode, isMenuVisible: Bool) -> Bool {
        !mode.routesAudio || isMenuVisible
    }
}
