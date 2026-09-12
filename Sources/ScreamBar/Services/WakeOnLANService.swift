import Foundation
import os

private let wakeOnLANLogger = Logger(
    subsystem: "com.screambar.app",
    category: "WakeOnLANService"
)
private let wakeOnLANMagicPacketPort: UInt16 = 9

enum WakeOnLANReachability: Equatable, Sendable {
    case unavailable
    case offline
    case online
}

@MainActor
final class WakeOnLANService: ObservableObject {
    private static let monitorIntervalNanoseconds: UInt64 = 5_000_000_000

    @Published private(set) var reachability: WakeOnLANReachability = .unavailable
    @Published private(set) var isSending = false
    @Published private var packetSendError: String?
    @Published private var pingError: String?
    @Published private(set) var lastSentAt: Date?

    private let burstSender: WakeOnLANPacketBurstSender
    private let hostPinger: any WakeOnLANHostPinging
    private weak var logStore: RollingLogStore?
    private var configuration = WakeOnLANConfiguration()
    private var monitorTask: Task<Void, Never>?
    private var activePing: (id: UUID, task: Task<Bool, Error>)?
    private var configurationRevision: UInt64 = 0
    private var isInterfaceVisible = false

    init(
        packetSender: any WakeOnLANPacketSending = UDPMagicPacketSender(),
        hostPinger: any WakeOnLANHostPinging = SystemPingService(),
        logStore: RollingLogStore? = nil
    ) {
        self.burstSender = WakeOnLANPacketBurstSender(packetSender: packetSender)
        self.hostPinger = hostPinger
        self.logStore = logStore
    }

    deinit {
        monitorTask?.cancel()
        activePing?.task.cancel()
    }

    var lastError: String? {
        packetSendError ?? pingError
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

    var monitoredHostDescription: String? {
        guard configuration.isEnabled,
              let destination = try? WakeOnLANDestination(configuration.destination) else {
            return nil
        }
        return destination.monitoredHost?.description
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
        cancelMonitoring()
        packetSendError = nil
        pingError = nil
        lastSentAt = nil
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
        cancelMonitoring()
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
        packetSendError = nil
        let requestedConfiguration = configuration
        defer { isSending = false }

        let packet = WakeOnLANMagicPacket.make(
            for: activeConfiguration.macAddress
        )
        let packetAddress = activeConfiguration.destination.packetAddress
        do {
            let outcome = try await burstSender.send(
                packet: packet,
                to: packetAddress,
                port: wakeOnLANMagicPacketPort
            )
            try Task.checkCancellation()
            guard requestedConfiguration == configuration else { return }
            if outcome.sentPacketCount > 0 {
                lastSentAt = Date()
            }
            let message = "\(outcome.sentPacketCount)/\(WakeOnLANPacketBurstSender.packetCount) magic packets sent to \(packetAddress):\(wakeOnLANMagicPacketPort)"
            if let failure = outcome.lastFailureDescription {
                publishFailure("\(message). \(failure)")
            } else {
                wakeOnLANLogger.info("\(message, privacy: .public)")
                logStore?.append(source: .wol, message: message)
            }
            Task { [weak self] in
                await self?.refreshReachability()
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestedConfiguration == configuration else { return }
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
                    self.publishFailure(error.localizedDescription, isPingFailure: true)
                    return
                }
            }
        }
    }

    private func cancelMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        activePing?.task.cancel()
        activePing = nil
    }

    private func refreshReachability(host: IPv4Address) async {
        await refreshReachability(host: host, revision: configurationRevision)
    }

    private func refreshReachability(
        host: IPv4Address,
        revision: UInt64
    ) async {
        guard revision == configurationRevision,
              !Task.isCancelled,
              activePing == nil else { return }
        let pingID = UUID()
        let hostPinger = hostPinger
        let pingTask = Task { try await hostPinger.ping(host: host) }
        activePing = (pingID, pingTask)
        defer {
            if activePing?.id == pingID {
                activePing = nil
            }
        }
        do {
            let isReachable = try await withTaskCancellationHandler {
                try await pingTask.value
            } onCancel: {
                pingTask.cancel()
            }
            try Task.checkCancellation()
            guard revision == configurationRevision,
                  activePing?.id == pingID else { return }
            reachability = isReachable ? .online : .offline
            pingError = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == configurationRevision,
                  activePing?.id == pingID else { return }
            reachability = .unavailable
            publishFailure(error.localizedDescription, isPingFailure: true)
        }
    }

    private func publishFailure(_ message: String, isPingFailure: Bool = false) {
        if isPingFailure {
            guard pingError != message else { return }
            pingError = message
        } else {
            packetSendError = message
        }
        wakeOnLANLogger.error("\(message, privacy: .public)")
        logStore?.append(source: .wol, message: message)
    }
}
