@testable import ScreamBar
import XCTest

final class WakeOnLANAddressTests: XCTestCase {
    func testMACAddressAcceptsCommonFormats() throws {
        let expectedBytes: [UInt8] = [0x00, 0x11, 0x22, 0xAA, 0xBB, 0xFF]

        XCTAssertEqual(
            try WakeOnLANMACAddress("00:11:22:aa:bb:ff").bytes,
            expectedBytes
        )
        XCTAssertEqual(
            try WakeOnLANMACAddress("00-11-22-AA-BB-FF").bytes,
            expectedBytes
        )
        XCTAssertEqual(
            try WakeOnLANMACAddress("0011.22AA.BBFF").bytes,
            expectedBytes
        )
    }

    func testMACAddressRejectsMalformedValues() {
        XCTAssertThrowsError(try WakeOnLANMACAddress("00:11:22:33:44")) {
            XCTAssertEqual($0 as? WakeOnLANError, .invalidMACAddress)
        }
        XCTAssertThrowsError(try WakeOnLANMACAddress("00:11:22:33:44:GG")) {
            XCTAssertEqual($0 as? WakeOnLANError, .invalidMACAddress)
        }
    }

    func testMagicPacketContainsSynchronizationBytesAndSixteenMACCopies() throws {
        let macAddress = try WakeOnLANMACAddress("00:11:22:33:44:55")

        let packet = [UInt8](WakeOnLANMagicPacket.make(for: macAddress))

        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        for repetition in 0..<16 {
            let startIndex = 6 + (repetition * 6)
            XCTAssertEqual(
                Array(packet[startIndex..<(startIndex + 6)]),
                macAddress.bytes
            )
        }
    }

    func testHostDestinationIsUsedForSendingAndMonitoring() throws {
        let destination = try WakeOnLANDestination("10.2.3.4")

        XCTAssertEqual(destination.packetAddress.description, "10.2.3.4")
        XCTAssertEqual(destination.monitoredHost?.description, "10.2.3.4")
    }

    func testCIDRDestinationCalculatesDirectedBroadcastAddress() throws {
        let destination = try WakeOnLANDestination("10.2.3.4/16")

        XCTAssertEqual(destination.packetAddress.description, "10.2.255.255")
        XCTAssertNil(destination.monitoredHost)
        XCTAssertEqual(
            destination,
            .subnet(
                network: try IPv4Address("10.2.0.0"),
                prefixLength: 16
            )
        )
    }

    func testCIDREdgePrefixesAreCalculatedCorrectly() throws {
        XCTAssertEqual(
            try WakeOnLANDestination("10.2.3.4/32").packetAddress.description,
            "10.2.3.4"
        )
        XCTAssertEqual(
            try WakeOnLANDestination("10.2.3.4/0").packetAddress.description,
            "255.255.255.255"
        )
    }

    func testDestinationRejectsInvalidIPv4AndPrefix() {
        for value in ["", "10.2.3", "10.2.3.256", "10.2.0.0/33", "host.local"] {
            XCTAssertThrowsError(try WakeOnLANDestination(value)) {
                XCTAssertEqual($0 as? WakeOnLANError, .invalidDestination)
            }
        }
    }
}
