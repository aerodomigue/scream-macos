@testable import ScreamBar
import Foundation
import XCTest

@MainActor
final class WakeOnLANServiceTests: XCTestCase {
    func testSendUsesResolvedBroadcastPortAndMagicPacket() async throws {
        let packetSender = RecordingMagicPacketSender()
        let hostPinger = RecordingHostPinger(response: false)
        let logStore = RollingLogStore()
        let service = WakeOnLANService(
            packetSender: packetSender,
            hostPinger: hostPinger,
            logStore: logStore
        )
        service.configurationDidChange(
            WakeOnLANConfiguration(
                isEnabled: true,
                macAddress: "00:11:22:33:44:55",
                destination: "10.2.0.0/16"
            )
        )

        await service.sendMagicPacket()

        let send = try XCTUnwrap(packetSender.sends.first)
        XCTAssertEqual(send.address.description, "10.2.255.255")
        XCTAssertEqual(send.port, 9)
        XCTAssertEqual(send.packet.count, 102)
        XCTAssertNotNil(service.lastSentAt)
        XCTAssertTrue(
            logStore.entries.contains {
                $0.source == .wol
                    && $0.message == "Magic packet sent to 10.2.255.255:9"
            }
        )
    }

    func testInvalidConfigurationDoesNotSend() async {
        let packetSender = RecordingMagicPacketSender()
        let service = WakeOnLANService(
            packetSender: packetSender,
            hostPinger: RecordingHostPinger(response: false)
        )
        service.configurationDidChange(
            WakeOnLANConfiguration(
                isEnabled: true,
                macAddress: "invalid",
                destination: "10.2.0.0/16"
            )
        )

        await service.sendMagicPacket()

        XCTAssertTrue(packetSender.sends.isEmpty)
        XCTAssertEqual(service.lastError, "Enter a valid 6-byte MAC address")
        XCTAssertFalse(service.isMagicPacketSendEnabled)
    }

    func testHostPingRunsOnlyWhileMenuInterfaceIsVisible() async throws {
        let hostPinger = RecordingHostPinger(response: false)
        let service = WakeOnLANService(
            packetSender: RecordingMagicPacketSender(),
            hostPinger: hostPinger
        )
        service.configurationDidChange(validHostConfiguration)

        try await Task.sleep(nanoseconds: 30_000_000)
        let hiddenCallCount = await hostPinger.callCount
        XCTAssertEqual(hiddenCallCount, 0)
        XCTAssertEqual(service.reachability, .unavailable)

        service.setInterfaceVisible(true)
        try await waitUntil { service.reachability == .offline }
        let visibleCallCount = await hostPinger.callCount
        XCTAssertEqual(visibleCallCount, 1)
        XCTAssertTrue(service.isMagicPacketSendEnabled)

        service.setInterfaceVisible(false)
        XCTAssertEqual(service.reachability, .unavailable)
        let callCountAfterClosing = await hostPinger.callCount
        try await Task.sleep(nanoseconds: 50_000_000)
        let finalCallCount = await hostPinger.callCount
        XCTAssertEqual(finalCallCount, callCountAfterClosing)
    }

    func testOnlineHostDisablesMagicPacketButton() async throws {
        let packetSender = RecordingMagicPacketSender()
        let service = WakeOnLANService(
            packetSender: packetSender,
            hostPinger: RecordingHostPinger(response: true)
        )
        service.configurationDidChange(validHostConfiguration)

        service.setInterfaceVisible(true)
        try await waitUntil { service.reachability == .online }

        XCTAssertFalse(service.isMagicPacketSendEnabled)

        await service.sendMagicPacket()

        XCTAssertTrue(packetSender.sends.isEmpty)
    }

    func testDisabledConfigurationIgnoresProgrammaticSend() async {
        let packetSender = RecordingMagicPacketSender()
        let service = WakeOnLANService(
            packetSender: packetSender,
            hostPinger: RecordingHostPinger(response: false)
        )

        await service.sendMagicPacket()

        XCTAssertTrue(packetSender.sends.isEmpty)
        XCTAssertNil(service.lastError)
    }

    func testSubnetDestinationDoesNotStartPingMonitor() async throws {
        let hostPinger = RecordingHostPinger(response: true)
        let service = WakeOnLANService(
            packetSender: RecordingMagicPacketSender(),
            hostPinger: hostPinger
        )
        service.configurationDidChange(
            WakeOnLANConfiguration(
                isEnabled: true,
                macAddress: "00:11:22:33:44:55",
                destination: "10.2.0.0/16"
            )
        )

        service.setInterfaceVisible(true)
        try await Task.sleep(nanoseconds: 30_000_000)

        let callCount = await hostPinger.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(service.reachability, .unavailable)
        XCTAssertTrue(service.isMagicPacketSendEnabled)
    }

    func testPacketSendFailureIsPublishedAndLogged() async {
        let logStore = RollingLogStore()
        let service = WakeOnLANService(
            packetSender: RecordingMagicPacketSender(
                error: WakeOnLANError.sendFailed(65)
            ),
            hostPinger: RecordingHostPinger(response: false),
            logStore: logStore
        )
        service.configurationDidChange(validHostConfiguration)

        await service.sendMagicPacket()

        XCTAssertEqual(
            service.lastError,
            "Could not send the magic packet (errno 65)"
        )
        XCTAssertTrue(
            logStore.entries.contains {
                $0.source == .wol && $0.message == service.lastError
            }
        )
    }

    private var validHostConfiguration: WakeOnLANConfiguration {
        WakeOnLANConfiguration(
            isEnabled: true,
            macAddress: "00:11:22:33:44:55",
            destination: "10.2.3.4"
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting for WOL state")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class RecordingMagicPacketSender: WakeOnLANPacketSending, @unchecked Sendable {
    struct Send {
        let packet: Data
        let address: IPv4Address
        let port: UInt16
    }

    private let lock = NSLock()
    private let error: WakeOnLANError?
    private var recordedSends: [Send] = []

    init(error: WakeOnLANError? = nil) {
        self.error = error
    }

    var sends: [Send] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSends
    }

    func send(packet: Data, to address: IPv4Address, port: UInt16) throws {
        if let error {
            throw error
        }
        lock.lock()
        recordedSends.append(Send(packet: packet, address: address, port: port))
        lock.unlock()
    }
}

private actor RecordingHostPinger: WakeOnLANHostPinging {
    private let response: Bool
    private(set) var hosts: [IPv4Address] = []

    init(response: Bool) {
        self.response = response
    }

    var callCount: Int {
        hosts.count
    }

    func ping(host: IPv4Address) async throws -> Bool {
        hosts.append(host)
        return response
    }
}
