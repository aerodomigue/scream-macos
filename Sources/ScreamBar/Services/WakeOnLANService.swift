import Foundation
import os

private let wakeOnLANLogger = Logger(
    subsystem: "com.screambar.app",
    category: "WakeOnLANService"
)
private let wakeOnLANMagicPacketPort: UInt16 = 9

enum WakeOnLANReachability: Equatable, Sendable {
    case unavailable
    case checking
    case offline
    case online
}

@MainActor
final class WakeOnLANService: ObservableObject {
    private static let monitorIntervalNanoseconds: UInt64 = 5_000_000_000

    @Published private(set) var reachability: WakeOnLANReachability = .unavailable
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSentAt: Date?

    private let packetSender: any WakeOnLANPacketSending
    private let hostPinger: any WakeOnLANHostPinging
    private weak var logStore: RollingLogStore?
    private var configuration = WakeOnLANConfiguration()
    private var monitorTask: Task<Void, Never>?
    private var configurationRevision: UInt64 = 0
    private var isInterfaceVisible = false

    init(
        packetSender: any WakeOnLANPacketSending = UDPMagicPacketSender(),
        hostPinger: any WakeOnLANHostPinging = SystemPingService(),
        logStore: RollingLogStore? = nil
    ) {
        self.packetSender = packetSender
        self.hostPinger = hostPinger
        self.logStore = logStore
    }

    deinit {
        monitorTask?.cancel()
    }

    var configurationErrorDescription: String? {
        guard configuration.isEnabled else { return nil }
        do {
            _ = try resolvedConfiguration()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var resolvedPacketDestinationDescription: String? {
        guard configuration.isEnabled,
              let destination = try? WakeOnLANDestination(configuration.destination) else {
            return nil
        }
        return destination.packetAddress.description
    }

    var isMagicPacketSendEnabled: Bool {
        configuration.isEnabled
            && configurationErrorDescription == nil
            && !isSending
            && reachability != .online
    }

    func configurationDidChange(_ newConfiguration: WakeOnLANConfiguration) {
        guard newConfiguration != configuration else { return }
        configuration = newConfiguration
        configurationRevision &+= 1
        monitorTask?.cancel()
        monitorTask = nil
        lastError = nil
        reachability = .unavailable

        guard isInterfaceVisible,
              configuration.isEnabled,
              let destination = try? WakeOnLANDestination(configuration.destination),
              let monitoredHost = destination.monitoredHost else {
            return
        }
        startMonitoring(host: monitoredHost, revision: configurationRevision)
    }

    func setInterfaceVisible(_ isVisible: Bool) {
        guard isVisible != isInterfaceVisible else { return }
        isInterfaceVisible = isVisible
        configurationRevision &+= 1
        monitorTask?.cancel()
        monitorTask = nil
        reachability = .unavailable

        guard isVisible,
              configuration.isEnabled,
              let destination = try? WakeOnLANDestination(configuration.destination),
              let monitoredHost = destination.monitoredHost else {
            return
        }
        startMonitoring(host: monitoredHost, revision: configurationRevision)
    }

    func sendMagicPacket() async {
        guard configuration.isEnabled,
              !isSending,
              reachability != .online else { return }

        let activeConfiguration: (
            macAddress: WakeOnLANMACAddress,
            destination: WakeOnLANDestination
        )
        do {
            activeConfiguration = try resolvedConfiguration()
        } catch {
            publishFailure(error.localizedDescription)
            return
        }

        isSending = true
        lastError = nil
        defer { isSending = false }

        let packet = WakeOnLANMagicPacket.make(
            for: activeConfiguration.macAddress
        )
        let packetAddress = activeConfiguration.destination.packetAddress
        do {
            let packetSender = packetSender
            try await Task.detached(priority: .userInitiated) {
                try packetSender.send(
                    packet: packet,
                    to: packetAddress,
                    port: wakeOnLANMagicPacketPort
                )
            }.value
            lastSentAt = Date()
            let message = "Magic packet sent to \(packetAddress):\(wakeOnLANMagicPacketPort)"
            wakeOnLANLogger.info("\(message, privacy: .public)")
            logStore?.append(source: .wol, message: message)

            if isInterfaceVisible,
               let monitoredHost = activeConfiguration.destination.monitoredHost {
                await refreshReachability(host: monitoredHost)
            }
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    func refreshReachability() async {
        guard isInterfaceVisible,
              configuration.isEnabled,
              let destination = try? WakeOnLANDestination(configuration.destination),
              let monitoredHost = destination.monitoredHost else {
            reachability = .unavailable
            return
        }
        await refreshReachability(host: monitoredHost)
    }

    private func resolvedConfiguration() throws -> (
        macAddress: WakeOnLANMACAddress,
        destination: WakeOnLANDestination
    ) {
        guard configuration.isEnabled else {
            throw WakeOnLANError.invalidDestination
        }
        return (
            try WakeOnLANMACAddress(configuration.macAddress),
            try WakeOnLANDestination(configuration.destination)
        )
    }

    private func startMonitoring(host: IPv4Address, revision: UInt64) {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshReachability(host: host, revision: revision)
                do {
                    try await Task.sleep(
                        nanoseconds: Self.monitorIntervalNanoseconds
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self.publishFailure(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func refreshReachability(host: IPv4Address) async {
        await refreshReachability(host: host, revision: configurationRevision)
    }

    private func refreshReachability(
        host: IPv4Address,
        revision: UInt64
    ) async {
        reachability = .checking
        do {
            let isReachable = try await hostPinger.ping(host: host)
            guard revision == configurationRevision else { return }
            reachability = isReachable ? .online : .offline
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == configurationRevision else { return }
            reachability = .unavailable
            publishFailure(error.localizedDescription)
        }
    }

    private func publishFailure(_ message: String) {
        lastError = message
        wakeOnLANLogger.error("\(message, privacy: .public)")
        logStore?.append(source: .wol, message: message)
    }
}
