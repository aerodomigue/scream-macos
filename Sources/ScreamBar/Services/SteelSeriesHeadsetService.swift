import Combine
import Foundation

@MainActor
final class SteelSeriesHeadsetService: ObservableObject {
    private static let POLL_INTERVAL_NANOSECONDS: UInt64 = 5_000_000_000
    private static let MINIMUM_LOG_INTERVAL: TimeInterval = 30

    @Published private(set) var state: SteelSeriesHeadsetState = .disabled
    private let transport: SteelSeriesStatusReading
    private weak var logStore: RollingLogStore?
    private let pollInterval: UInt64
    private var monitoringTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var lastLoggedDescription: String?
    private var lastLogDate: Date = .distantPast

    init(
        logStore: RollingLogStore,
        transport: SteelSeriesStatusReading? = nil,
        pollInterval: UInt64? = nil
    ) {
        self.logStore = logStore
        self.transport = transport ?? SteelSeriesHIDTransport()
        self.pollInterval = pollInterval ?? Self.POLL_INTERVAL_NANOSECONDS
    }

    deinit { monitoringTask?.cancel() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (monitoringTask != nil) else { return }
        revision &+= 1
        monitoringTask?.cancel()
        monitoringTask = nil
        guard enabled else {
            state = .disabled
            return
        }
        state = .checking
        let currentRevision = revision
        let transport = transport
        let pollInterval = pollInterval
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await transport.readStatus()
                guard !Task.isCancelled, self?.revision == currentRevision else { return }
                self?.publish(snapshot)
                do {
                    try await Task.sleep(nanoseconds: pollInterval)
                } catch is CancellationError {
                    return
                } catch {
                    self?.publish(.failed("Headset monitoring interrupted: \(error.localizedDescription)"))
                    return
                }
            }
        }
    }

    private func publish(_ snapshot: SteelSeriesHeadsetState) {
        if state != snapshot { state = snapshot }
        let description = snapshot.connectionDescription
        // Battery polls are silent; even a flapping USB link logs at most twice a minute.
        guard description != lastLoggedDescription,
              Date().timeIntervalSince(lastLogDate) >= Self.MINIMUM_LOG_INTERVAL else { return }
        lastLoggedDescription = description
        lastLogDate = Date()
        logStore?.append(source: .app, message: "SteelSeries Omni: \(description)")
    }
}
