import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

@MainActor
protocol VolumeFeedbackPlaying: AnyObject {
    func prepare(outputUID: String) throws
    func play(request: SteelSeriesVolumeRequest) throws
    func silence()
    func stop()
}

struct VolumeFeedbackFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Restarts the native volume sample without queuing sounds or restarting audio hardware per key.
@MainActor
final class VolumeFeedbackSoundService: VolumeFeedbackPlaying {
    private static let SOUND_PATH = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    private let isEnabled: () throws -> Bool
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    private var outputUID: String?

    init(isEnabled: @escaping () throws -> Bool = MacOSVolumeFeedbackPreference.isEnabled) {
        self.isEnabled = isEnabled
    }

    func prepare(outputUID: String) throws {
        guard try isEnabled() else { stop(); return }
        if self.outputUID == outputUID, engine?.isRunning == true { return }
        stop()
        let sample = try loadSample()
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        let device = try CoreAudioPropertyReader.readAudioDeviceID(objectID: AudioObjectID(kAudioObjectSystemObject),
            address: Self.address(kAudioHardwarePropertyDefaultOutputDevice))
        let selectedUID = try CoreAudioPropertyReader.readString(objectID: device,
            address: Self.address(kAudioDevicePropertyDeviceUID))
        guard selectedUID == outputUID, let audioUnit = newEngine.outputNode.audioUnit else {
            throw VolumeFeedbackFailure(message: "The volume feedback output changed")
        }
        var selectedDevice = device
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &selectedDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Select volume feedback output", status: status)
        }
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: sample.format)
        newEngine.prepare()
        try newEngine.start()
        newPlayer.play()
        engine = newEngine
        player = newPlayer
        self.outputUID = outputUID
    }

    func play(request: SteelSeriesVolumeRequest) throws {
        guard try isEnabled() else { stop(); return }
        try request.validate()
        guard let outputUID = request.outputUID else {
            throw VolumeFeedbackFailure(message: "No volume feedback output was selected")
        }
        if self.outputUID != outputUID || engine?.isRunning != true { try prepare(outputUID: outputUID) }
        // Preparation can take time; never rely on permission or routing observed before it.
        guard try isEnabled() else { stop(); return }
        try request.validate()
        guard let player, let buffer, engine?.isRunning == true else {
            throw VolumeFeedbackFailure(message: "The volume feedback output is unavailable")
        }
        if !player.isPlaying { player.play() }
        // The async overload waits for playback completion; only schedule the restart here.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    func silence() { player?.stop() }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        outputUID = nil
    }

    private func loadSample() throws -> AVAudioPCMBuffer {
        if let buffer { return buffer }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: Self.SOUND_PATH))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VolumeFeedbackFailure(message: "Could not load the macOS volume feedback sample")
        }
        try file.read(into: buffer)
        self.buffer = buffer
        return buffer
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
