import Foundation

/// Encodes the Omni volume protocol verified with the USB1 hardware POC.
struct SteelSeriesVolume: Equatable, Sendable {
    static let SETTINGS_OPCODE: UInt8 = 0x20
    static let VOLUME_OPCODE: UInt8 = 0x25
    static let SETTINGS_LENGTH = 256
    static let VOLUME_OFFSET = 142
    static let MAX_ATTENUATION = 56
    // Only settings reads need time for the base to prepare its feature report.
    static let READ_RESPONSE_SETTLE_SECONDS: TimeInterval = 0.05

    let attenuation: UInt8

    init?(settings: [UInt8]) {
        // GET_REPORT returns the opcode first, without the HID report ID.
        guard settings.count == Self.SETTINGS_LENGTH,
              settings[0] == Self.SETTINGS_OPCODE,
              settings[Self.VOLUME_OFFSET] <= Self.MAX_ATTENUATION else { return nil }
        attenuation = settings[Self.VOLUME_OFFSET]
    }

    private init(attenuation: UInt8) { self.attenuation = attenuation }

    var percentage: Int {
        Int((Double(Self.MAX_ATTENUATION - Int(attenuation)) * 100 / Double(Self.MAX_ATTENUATION)).rounded())
    }

    func adjusted(by steps: Int) -> Self {
        let boundedSteps = max(-Self.MAX_ATTENUATION, min(Self.MAX_ATTENUATION, steps))
        return Self(attenuation: UInt8(max(0, min(Self.MAX_ATTENUATION, Int(attenuation) - boundedSteps))))
    }

    static var readRequest: [UInt8] { command(opcode: SETTINGS_OPCODE) }

    var writeRequest: [UInt8] { Self.command(opcode: Self.VOLUME_OPCODE, value: attenuation) }

    private static func command(opcode: UInt8, value: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: SteelSeriesHeadsetStatus.REPORT_LENGTH)
        bytes[0] = UInt8(SteelSeriesHeadsetStatus.REPORT_ID)
        bytes[1] = opcode
        bytes[2] = value
        return bytes
    }
}

/// Combines ordered key presses in constant space, including reversals at 0/100%.
struct SteelSeriesVolumeChange: Sendable {
    private var shift = 0
    private var lowerBound = 0
    private var upperBound = SteelSeriesVolume.MAX_ATTENUATION
    private(set) var isEmpty = true

    init() {}

    init(target: SteelSeriesVolume) {
        lowerBound = SteelSeriesVolume.MAX_ATTENUATION - Int(target.attenuation)
        upperBound = lowerBound
        isEmpty = false
    }

    mutating func append(_ step: Int) {
        precondition(step == 1 || step == -1)
        isEmpty = false
        shift += step
        lowerBound = Self.clamp(lowerBound + step)
        upperBound = Self.clamp(upperBound + step)
        if lowerBound == upperBound { shift = 0 }
    }

    func applying(to volume: SteelSeriesVolume) -> SteelSeriesVolume {
        let level = SteelSeriesVolume.MAX_ATTENUATION - Int(volume.attenuation)
        let target = max(lowerBound, min(upperBound, level + shift))
        return volume.adjusted(by: target - level)
    }

    private static func clamp(_ level: Int) -> Int {
        max(0, min(SteelSeriesVolume.MAX_ATTENUATION, level))
    }
}
