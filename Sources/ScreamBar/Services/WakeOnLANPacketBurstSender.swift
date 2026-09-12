import Foundation

struct WakeOnLANPacketBurstOutcome: Sendable {
    let sentPacketCount: Int
    let lastFailureDescription: String?
}

struct WakeOnLANPacketBurstSender: Sendable {
    static let packetCount = 6
    private static let packetIntervalNanoseconds: UInt64 = 100_000_000

    let packetSender: any WakeOnLANPacketSending

    /// Attempts every packet, retaining partial failures without blocking the UI.
    func send(
        packet: Data,
        to address: IPv4Address,
        port: UInt16
    ) async throws -> WakeOnLANPacketBurstOutcome {
        let sendTask = Task.detached(priority: .userInitiated) {
            var sentPacketCount = 0
            var lastFailureDescription: String?
            for packetIndex in 0..<Self.packetCount {
                try Task.checkCancellation()
                do {
                    try packetSender.send(packet: packet, to: address, port: port)
                    sentPacketCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastFailureDescription = error.localizedDescription
                }
                if packetIndex < Self.packetCount - 1 {
                    try await Task.sleep(nanoseconds: Self.packetIntervalNanoseconds)
                }
            }
            return WakeOnLANPacketBurstOutcome(
                sentPacketCount: sentPacketCount,
                lastFailureDescription: lastFailureDescription
            )
        }
        return try await withTaskCancellationHandler {
            try await sendTask.value
        } onCancel: {
            sendTask.cancel()
        }
    }
}
