import Foundation

struct EffectiveAudioRoute: Equatable, Sendable {
    let input: AudioDeviceDescriptor
    let output: AudioDeviceDescriptor
    let nominalSampleRate: Double
    let isUsingOutputFallback: Bool
}

struct PreparedAudioRoute: Equatable, Sendable {
    let sessionID: UUID
    let route: EffectiveAudioRoute
}

enum AudioRoutingState: Equatable, Sendable {
    case stopped
    case starting
    case running(EffectiveAudioRoute)
    case reconfiguring
    case waitingForInput
    case waitingForOutput
    case stopping
    case failed(AudioRoutingError)

    var processStatus: ProcessStatus {
        switch self {
        case .stopped, .waitingForInput, .waitingForOutput:
            return .stopped
        case .starting, .reconfiguring:
            return .starting
        case .running:
            return .running
        case .stopping:
            return .stopping
        case .failed(let error):
            return .error(error.localizedDescription)
        }
    }
}
