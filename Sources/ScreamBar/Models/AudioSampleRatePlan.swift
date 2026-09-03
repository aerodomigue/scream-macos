import Foundation

enum AudioSampleRatePlan: Equatable, Sendable {
    case synchronized(sampleRate: Double)
    case converted(inputSampleRate: Double, outputSampleRate: Double)

    var inputSampleRate: Double {
        switch self {
        case .synchronized(let sampleRate):
            return sampleRate
        case .converted(let inputSampleRate, _):
            return inputSampleRate
        }
    }

    var outputSampleRate: Double {
        switch self {
        case .synchronized(let sampleRate):
            return sampleRate
        case .converted(_, let outputSampleRate):
            return outputSampleRate
        }
    }

    var usesSampleRateConversion: Bool {
        if case .converted = self {
            return true
        }
        return false
    }
}
