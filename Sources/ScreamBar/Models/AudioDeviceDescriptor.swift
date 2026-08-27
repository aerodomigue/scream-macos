import Foundation

struct NominalSampleRateRange: Codable, Equatable, Sendable {
    let minimum: Double
    let maximum: Double
}

struct AudioDeviceDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: AudioDeviceUID
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let isAlive: Bool
    let currentNominalSampleRate: Double
    let supportedNominalSampleRates: [NominalSampleRateRange]
    let currentBufferFrameSize: UInt32?
    let supportedBufferFrameSizeRange: AudioBufferFrameSizeRange?

    init(
        id: AudioDeviceUID,
        name: String,
        inputChannelCount: Int,
        outputChannelCount: Int,
        isAlive: Bool,
        currentNominalSampleRate: Double,
        supportedNominalSampleRates: [NominalSampleRateRange],
        currentBufferFrameSize: UInt32? = nil,
        supportedBufferFrameSizeRange: AudioBufferFrameSizeRange? = nil
    ) {
        self.id = id
        self.name = name
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.isAlive = isAlive
        self.currentNominalSampleRate = currentNominalSampleRate
        self.supportedNominalSampleRates = supportedNominalSampleRates
        self.currentBufferFrameSize = currentBufferFrameSize
        self.supportedBufferFrameSizeRange = supportedBufferFrameSizeRange
    }

    var supportsInput: Bool {
        inputChannelCount > 0
    }

    var supportsOutput: Bool {
        outputChannelCount > 0
    }
}

struct AudioHardwareSnapshot: Equatable, Sendable {
    let revision: UInt64
    let devices: [AudioDeviceDescriptor]
    let defaultInputUID: AudioDeviceUID?
    let defaultOutputUID: AudioDeviceUID?

    var inputDevices: [AudioDeviceDescriptor] {
        devices.filter(\.supportsInput)
    }

    var outputDevices: [AudioDeviceDescriptor] {
        devices.filter(\.supportsOutput)
    }

    func device(withUID uid: AudioDeviceUID) -> AudioDeviceDescriptor? {
        devices.first { $0.id == uid }
    }
}
