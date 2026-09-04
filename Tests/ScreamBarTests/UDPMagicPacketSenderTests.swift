@testable import ScreamBar
import Darwin
import XCTest

final class UDPMagicPacketSenderTests: XCTestCase {
    func testSenderDeliversDatagramToIPv4Loopback() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { close(receiver) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        XCTAssertEqual(
            setsockopt(
                receiver,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout.size(ofValue: timeout))
            ),
            0
        )

        var receiverAddress = sockaddr_in()
        receiverAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        receiverAddress.sin_family = sa_family_t(AF_INET)
        receiverAddress.sin_port = 0
        receiverAddress.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindStatus = withUnsafePointer(to: &receiverAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    receiver,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        XCTAssertEqual(bindStatus, 0)

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(receiver, $0, &boundAddressLength)
            }
        }
        XCTAssertEqual(addressStatus, 0)

        let packet = Data([0x01, 0x02, 0x03, 0x04])
        try UDPMagicPacketSender().send(
            packet: packet,
            to: IPv4Address("127.0.0.1"),
            port: UInt16(bigEndian: boundAddress.sin_port)
        )

        var receivedBytes = [UInt8](repeating: 0, count: 16)
        let receivedByteCount = Darwin.recv(
            receiver,
            &receivedBytes,
            receivedBytes.count,
            0
        )

        XCTAssertEqual(receivedByteCount, packet.count)
        XCTAssertEqual(
            Array(receivedBytes.prefix(receivedByteCount)),
            [0x01, 0x02, 0x03, 0x04]
        )
    }
}
