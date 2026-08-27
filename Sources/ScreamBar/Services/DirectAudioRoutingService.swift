import Combine
import Foundation
import os

private let directRoutingLogger = Logger(
    subsystem: "com.screambar.app",
    category: "DirectAudioRoutingService"
)

@MainActor
final class DirectAudioRoutingService: ObservableObject {
    @Published private(set) var state: AudioRoutingState = .stopped
    @Published private(set) var desiredRunning = false

    let deviceService: CoreAudioDeviceService

    private let permissionService: any AudioInputPermissionServicing
    private weak var logStore: RollingLogStore?
    private var configuration = DirectRoutingConfiguration()
    private var activeRoute: PreparedAudioRoute?
    private var workerTask: Task<Void, Never>?
    private var desiredRevision: UInt64 = 0

    init(
        logStore: RollingLogStore,
        deviceService: CoreAudioDeviceService? = nil,
        permissionService: (any AudioInputPermissionServicing)? = nil
    ) {
        self.logStore = logStore
        self.deviceService = deviceService ?? CoreAudioDeviceService(logStore: logStore)
        self.permissionService = permissionService ?? AudioInputPermissionService()
        self.deviceService.onHardwareChanged = { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.requestReconciliation(reason: "CoreAudio hardware changed")
        }
    }

    func start(configuration: DirectRoutingConfiguration) {
        self.configuration = configuration
        desiredRunning = true
        requestReconciliation(reason: "Starting Direct Routing")
    }

    func stop() {
        desiredRunning = false
        requestReconciliation(reason: "Stopping Direct Routing")
    }

    func stopImmediately() {
        desiredRunning = false
        desiredRevision &+= 1
        workerTask?.cancel()
        workerTask = nil
        if let activeRoute {
            do {
                try deviceService.stopAndDestroyRoute(sessionID: activeRoute.sessionID)
            } catch {
                report("Immediate Direct Routing cleanup failed: \(error.localizedDescription)")
            }
            self.activeRoute = nil
        }
        state = .stopped
    }

    func configurationDidChange(_ configuration: DirectRoutingConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        guard desiredRunning else { return }
        requestReconciliation(reason: "Direct Routing selection changed")
    }

    func shutdown() {
        stopImmediately()
        deviceService.shutdown()
    }

    private func requestReconciliation(reason: String) {
        desiredRevision &+= 1
        let revision = desiredRevision
        workerTask?.cancel()
        report(reason)
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcile(revision: revision)
        }
    }

    private func reconcile(revision: UInt64) async {
        if let activeRoute {
            state = desiredRunning ? .reconfiguring : .stopping
            do {
                try deviceService.stopAndDestroyRoute(sessionID: activeRoute.sessionID)
            } catch {
                report("Direct Routing cleanup failed: \(error.localizedDescription)")
                if revision == desiredRevision {
                    state = .failed(.cleanupFailed([error.localizedDescription]))
                }
                self.activeRoute = nil
                return
            }
            self.activeRoute = nil
        }

        guard revision == desiredRevision else { return }
        guard desiredRunning else {
            state = .stopped
            return
        }

        state = state == .reconfiguring ? .reconfiguring : .starting
        var preparedRoute: PreparedAudioRoute?
        do {
            try await permissionService.requestPermissionIfNeeded()
            guard revision == desiredRevision, desiredRunning else { return }

            let route = try await deviceService.prepareRoute(
                inputSelection: configuration.inputSelection,
                outputSelection: configuration.outputSelection,
                requestedBufferFrameSize: configuration.bufferSize.frameCount
            )
            preparedRoute = route

            guard revision == desiredRevision, desiredRunning else {
                try deviceService.stopAndDestroyRoute(sessionID: route.sessionID)
                return
            }

            try deviceService.startRoute(route)
            guard revision == desiredRevision, desiredRunning else {
                try deviceService.stopAndDestroyRoute(sessionID: route.sessionID)
                return
            }

            activeRoute = route
            state = .running(route.route)
            report(
                "Direct Routing active: \(route.route.input.name) → \(route.route.output.name) at \(Int(route.route.nominalSampleRate)) Hz"
            )
        } catch is CancellationError {
            if let preparedRoute {
                do {
                    try deviceService.stopAndDestroyRoute(sessionID: preparedRoute.sessionID)
                } catch {
                    report("Cancelled route cleanup failed: \(error.localizedDescription)")
                }
            }
        } catch let routingError as AudioRoutingError {
            if let preparedRoute {
                do {
                    try deviceService.stopAndDestroyRoute(sessionID: preparedRoute.sessionID)
                } catch {
                    report("Failed route cleanup failed: \(error.localizedDescription)")
                }
            }
            guard revision == desiredRevision else { return }
            apply(routingError)
        } catch {
            if let preparedRoute {
                do {
                    try deviceService.stopAndDestroyRoute(sessionID: preparedRoute.sessionID)
                } catch {
                    report("Unexpected route cleanup failed: \(error.localizedDescription)")
                }
            }
            guard revision == desiredRevision else { return }
            report("Unexpected Direct Routing error: \(error.localizedDescription)")
            state = .failed(.unexpected(error.localizedDescription))
        }
    }

    private func apply(_ error: AudioRoutingError) {
        report(error.localizedDescription)
        switch error {
        case .inputDeviceUnavailable:
            state = .waitingForInput
        case .outputDeviceUnavailable:
            state = .waitingForOutput
        default:
            state = .failed(error)
        }
    }

    private func report(_ message: String) {
        directRoutingLogger.info("\(message, privacy: .public)")
        logStore?.append(source: .routing, message: message)
    }
}
