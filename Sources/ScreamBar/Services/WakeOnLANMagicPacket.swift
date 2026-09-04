import Foundation

enum WakeOnLANMagicPacket {
    private static let synchronizationByte: UInt8 = 0xFF
    private static let synchronizationByteCount = 6
    private static let macRepetitionCount = 16

    static func make(for macAddress: WakeOnLANMACAddress) -> Data {
        var bytes = Array(
            repeating: synchronizationByte,
            count: synchronizationByteCount
        )
        bytes.reserveCapacity(
            synchronizationByteCount
                + (macAddress.bytes.count * macRepetitionCount)
        )
        for _ in 0..<macRepetitionCount {
            bytes.append(contentsOf: macAddress.bytes)
        }
        return Data(bytes)
    }
}
