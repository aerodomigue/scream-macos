import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "VolumeControl")

enum VolumeControl {
    static func getSystemVolume() -> Float {
        guard let deviceID = defaultOutputDeviceID() else { return 0.5 }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0.5
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            return volume
        }

        // Fallback: read left channel as proxy for master
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0.5
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            return volume
        }

        return 0.5
    }

    static func setSystemVolume(_ volume: Float) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var vol = Float32(max(0.0, min(1.0, volume)))

        var masterAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &masterAddress) {
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &masterAddress, &settable)
            if settable.boolValue {
                AudioObjectSetPropertyData(deviceID, &masterAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                return
            }
        }

        // Set per-channel if no settable master element
        for channel: UInt32 in [1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            if AudioObjectHasProperty(deviceID, &address) {
                var settable: DarwinBoolean = false
                AudioObjectIsPropertySettable(deviceID, &address, &settable)
                if settable.boolValue {
                    AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                }
            }
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.warning("Failed to get default output device: \(status)")
            return nil
        }
        return deviceID
    }
}
