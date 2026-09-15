import CoreAudio
import Foundation

/// Cancels queued USB writes when the mode, device or keyboard permission changes.
final class SteelSeriesVolumeRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let outputUID: String?

    // Read-only snapshots do not require Omni to be the default output.
    init(outputUID: String? = nil) { self.outputUID = outputUID }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func validate() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled else { throw CancellationError() }
        guard let outputUID else { return }
        let device = try CoreAudioPropertyReader.readAudioDeviceID(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        )
        let currentUID = try CoreAudioPropertyReader.readString(
            objectID: device, address: Self.address(kAudioDevicePropertyDeviceUID)
        )
        guard currentUID == outputUID else { throw CancellationError() }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

@MainActor
protocol SteelSeriesVolumeAdjusting: AnyObject {
    func adjustVolume(_ change: SteelSeriesVolumeChange, from current: SteelSeriesVolume?,
                      request: SteelSeriesVolumeRequest) async throws -> SteelSeriesVolume
    func readVolume(request: SteelSeriesVolumeRequest) async throws -> SteelSeriesVolume
}

extension SteelSeriesVolumeAdjusting {
    func adjustVolume(_ change: SteelSeriesVolumeChange, request: SteelSeriesVolumeRequest) async throws -> SteelSeriesVolume {
        try await adjustVolume(change, from: nil, request: request)
    }
}

struct SteelSeriesVolumeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
