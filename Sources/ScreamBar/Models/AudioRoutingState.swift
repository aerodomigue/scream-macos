import Foundation

struct EffectiveAudioRoute: Equatable, Sendable {
    let input: AudioDeviceDescriptor
    let output: AudioDeviceDescriptor
    let sampleRatePlan: AudioSampleRatePlan
    let isUsingOutputFallback: Bool
    let bufferFrameSize: UInt32?
    let estimatedApplicationLatencySeconds: Double?
    let maximumApplicationLatencySeconds: Double?
    let isLowLatency: Bool

    init(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        sampleRatePlan: AudioSampleRatePlan,
        isUsingOutputFallback: Bool,
        bufferFrameSize: UInt32? = nil,
        estimatedApplicationLatencySeconds: Double? = nil,
        maximumApplicationLatencySeconds: Double? = nil,
        isLowLatency: Bool = true
    ) {
        self.input = input
        self.output = output
        self.sampleRatePlan = sampleRatePlan
        self.isUsingOutputFallback = isUsingOutputFallback
        self.bufferFrameSize = bufferFrameSize
        self.estimatedApplicationLatencySeconds =
            estimatedApplicationLatencySeconds
        self.maximumApplicationLatencySeconds =
            maximumApplicationLatencySeconds
        self.isLowLatency = isLowLatency
    }

    var nominalSampleRate: Double {
        sampleRatePlan.outputSampleRate
    }

    var inputNominalSampleRate: Double {
        sampleRatePlan.inputSampleRate
    }

    var outputNominalSampleRate: Double {
        sampleRatePlan.outputSampleRate
    }

    var usesSampleRateConversion: Bool {
        sampleRatePlan.usesSampleRateConversion
    }
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
