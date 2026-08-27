import CoreAudio
import Foundation

struct CoreAudioBackendFailure: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let fourCC = Self.fourCCDescription(for: status)
        return "\(operation) failed with OSStatus \(status) (\(fourCC))"
    }

    private static func fourCCDescription(for status: OSStatus) -> String {
        let statusValue = UInt32(bitPattern: status)
        let characters = [
            UInt8((statusValue >> 24) & 0xFF),
            UInt8((statusValue >> 16) & 0xFF),
            UInt8((statusValue >> 8) & 0xFF),
            UInt8(statusValue & 0xFF),
        ]
        guard characters.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "non-printable"
        }
        return String(bytes: characters, encoding: .ascii) ?? "non-printable"
    }
}

enum CoreAudioPropertyReader {
    static func hasProperty(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        var mutableAddress = address
        return AudioObjectHasProperty(objectID, &mutableAddress)
    }

    static func readDeviceIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioDeviceID] {
        try readArray(objectID: objectID, address: address, as: AudioDeviceID.self)
    }

    static func readValueRanges(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioValueRange] {
        try readArray(objectID: objectID, address: address, as: AudioValueRange.self)
    }

    static func readAudioObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        try readArray(objectID: objectID, address: address, as: AudioObjectID.self)
    }

    static func readUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var value: UInt32 = 0
        try readScalar(objectID: objectID, address: address, value: &value)
        return value
    }

    static func readFloat64(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Float64 {
        var value: Float64 = 0
        try readScalar(objectID: objectID, address: address, value: &value)
        return value
    }

    static func readAudioDeviceID(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioDeviceID {
        var value = AudioDeviceID(kAudioObjectUnknown)
        try readScalar(objectID: objectID, address: address, value: &value)
        return value
    }

    static func readValueRange(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioValueRange {
        var value = AudioValueRange()
        try readScalar(objectID: objectID, address: address, value: &value)
        return value
    }

    static func readString(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> String {
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var mutableAddress = address
        let status = AudioObjectGetPropertyData(
            objectID,
            &mutableAddress,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let value else {
            throw CoreAudioBackendFailure(
                operation: "Read string property selector \(address.mSelector) from object \(objectID)",
                status: status
            )
        }
        return value.takeRetainedValue() as String
    }

    static func readChannelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Read channel configuration size", status: status)
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let audioBufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, audioBufferList)
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Read channel configuration", status: status)
        }

        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    static func writeFloat64(
        _ value: Float64,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws {
        var mutableValue = value
        var mutableAddress = address
        let status = AudioObjectSetPropertyData(
            objectID,
            &mutableAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Write Float64 property", status: status)
        }
    }

    static func writeUInt32(
        _ value: UInt32,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws {
        var mutableValue = value
        var mutableAddress = address
        let status = AudioObjectSetPropertyData(
            objectID,
            &mutableAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Write UInt32 property", status: status)
        }
    }

    private static func readArray<Element>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as elementType: Element.Type
    ) throws -> [Element] {
        var mutableAddress = address
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &mutableAddress, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Read array property size", status: status)
        }
        guard dataSize > 0 else { return [] }

        let elementCount = Int(dataSize) / MemoryLayout<Element>.stride
        let buffer = UnsafeMutablePointer<Element>.allocate(capacity: elementCount)
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &mutableAddress, 0, nil, &dataSize, buffer)
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Read array property", status: status)
        }
        return Array(UnsafeBufferPointer(start: buffer, count: elementCount))
    }

    private static func readScalar<Value>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        value: inout Value
    ) throws {
        var mutableAddress = address
        var dataSize = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { valueBytes in
            guard let baseAddress = valueBytes.baseAddress else {
                return kAudio_ParamError
            }
            return AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Read scalar property", status: status)
        }
    }
}
