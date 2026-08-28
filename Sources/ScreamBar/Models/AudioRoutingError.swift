import Foundation

struct SampleRateCompatibilityContext: Equatable, Sendable {
    let inputUID: AudioDeviceUID
    let outputUID: AudioDeviceUID
    let inputRanges: [NominalSampleRateRange]
    let outputRanges: [NominalSampleRateRange]
}

struct SampleRateConfigurationContext: Equatable, Sendable {
    let deviceUID: AudioDeviceUID
    let requestedRate: Double
    let observedRate: Double?
    let operation: String
}

struct BufferFrameSizeCompatibilityContext: Equatable, Sendable {
    let inputUID: AudioDeviceUID
    let outputUID: AudioDeviceUID
    let requestedFrameCount: UInt32
    let inputRange: AudioBufferFrameSizeRange?
    let outputRange: AudioBufferFrameSizeRange?
}

struct BufferFrameSizeConfigurationContext: Equatable, Sendable {
    let deviceUID: AudioDeviceUID
    let requestedFrameCount: UInt32
    let observedFrameCount: UInt32?
    let operation: String
}

struct AggregateDeviceContext: Equatable, Sendable {
    let inputUID: AudioDeviceUID
    let outputUID: AudioDeviceUID
    let nominalSampleRate: Double
}

struct AUHALContext: Equatable, Sendable {
    let inputUID: AudioDeviceUID
    let outputUID: AudioDeviceUID
    let nominalSampleRate: Double
}

enum AUHALConfigurationStage: String, Equatable, Sendable {
    case deviceBinding
    case inputIO
    case outputIO
    case clientStreamFormat
    case channelMapping
    case playthroughConnection
}

enum AudioRoutingError: LocalizedError, Equatable, Sendable {
    case inputPermissionDenied
    case inputDeviceUnavailable(AudioDeviceUID?)
    case outputDeviceUnavailable(AudioDeviceUID?)
    case noCommonSampleRate(SampleRateCompatibilityContext)
    case sampleRateConfigurationFailed(SampleRateConfigurationContext)
    case unsupportedBufferFrameSize(BufferFrameSizeCompatibilityContext)
    case bufferFrameSizeConfigurationFailed(BufferFrameSizeConfigurationContext)
    case aggregateDeviceUnsupported(AggregateDeviceContext)
    case aggregateCreationFailed(AggregateDeviceContext)
    case auHALCreationFailed(AUHALContext)
    case auHALConfigurationFailed(stage: AUHALConfigurationStage, context: AUHALContext)
    case auHALStartFailed(AUHALContext)
    case finalRouteValidationFailed(AUHALContext)
    case serviceShuttingDown
    case cleanupFailed([String])
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .inputPermissionDenied:
            return "Audio input permission is required for Direct Routing"
        case .inputDeviceUnavailable:
            return "The selected input device is unavailable"
        case .outputDeviceUnavailable:
            return "No output device is available"
        case .noCommonSampleRate:
            return "The selected devices do not share a nominal sample rate"
        case .sampleRateConfigurationFailed(let context):
            return "Failed to configure \(context.deviceUID.rawValue) at \(Int(context.requestedRate)) Hz"
        case .unsupportedBufferFrameSize(let context):
            return "The selected devices do not support \(context.requestedFrameCount) audio frames"
        case .bufferFrameSizeConfigurationFailed(let context):
            return "Failed to configure \(context.deviceUID.rawValue) at \(context.requestedFrameCount) audio frames"
        case .aggregateDeviceUnsupported:
            return "The selected devices cannot participate in a private Aggregate Device"
        case .aggregateCreationFailed:
            return "Failed to create the private Aggregate Device"
        case .auHALCreationFailed:
            return "Failed to create the AUHAL audio unit"
        case .auHALConfigurationFailed(let stage, _):
            return "Failed to configure AUHAL during \(stage.rawValue)"
        case .auHALStartFailed:
            return "Failed to start AUHAL"
        case .finalRouteValidationFailed:
            return "The audio route changed while it was being prepared"
        case .serviceShuttingDown:
            return "Direct Routing is shutting down"
        case .cleanupFailed(let stages):
            return "Audio cleanup failed during: \(stages.joined(separator: ", "))"
        case .unexpected(let message):
            return "Unexpected routing error: \(message)"
        }
    }
}
