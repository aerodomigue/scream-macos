import Darwin
import Foundation

protocol WakeOnLANPacketSending: Sendable {
    func send(packet: Data, to address: IPv4Address, port: UInt16) throws
}

struct UDPMagicPacketSender: WakeOnLANPacketSending {
    func send(packet: Data, to address: IPv4Address, port: UInt16) throws {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            throw WakeOnLANError.socketCreationFailed(errno)
        }
        defer { close(socketDescriptor) }

        var broadcastEnabled: Int32 = 1
        let optionStatus = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnabled,
            socklen_t(MemoryLayout.size(ofValue: broadcastEnabled))
        )
        guard optionStatus == 0 else {
            throw WakeOnLANError.broadcastConfigurationFailed(errno)
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr = in_addr(s_addr: address.rawValue.bigEndian)

        let sentByteCount = packet.withUnsafeBytes { packetBytes in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { socketAddress in
                    Darwin.sendto(
                        socketDescriptor,
                        packetBytes.baseAddress,
                        packetBytes.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        guard sentByteCount >= 0 else {
            throw WakeOnLANError.sendFailed(errno)
        }
        guard sentByteCount == packet.count else {
            throw WakeOnLANError.incompleteSend(
                expected: packet.count,
                actual: sentByteCount
            )
        }
    }
}
