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
    private(set) var isShuttingDown = false

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
            self.requestReconciliation(reason: "Direct Routing rebuilding after hardware change")
        }
    }

    func start(configuration: DirectRoutingConfiguration) {
        guard !isShuttingDown else {
            state = .failed(.serviceShuttingDown)
            return
        }
        self.configuration = configuration
        desiredRunning = true
        requestReconciliation(reason: "Starting Direct Routing")
    }

    func stop() {
        guard !isShuttingDown else { return }
        desiredRunning = false
        requestReconciliation(reason: "Stopping Direct Routing")
    }

    func stopAndWait() async throws {
        guard !isShuttingDown else {
            if activeRoute != nil {
                throw AudioRoutingError.cleanupFailed([
                    "Direct Routing still owns CoreAudio resources during shutdown",
                ])
            }
            return
        }
        desiredRunning = false
        requestReconciliation(reason: "Stopping Direct Routing with cleanup barrier")
        let task = workerTask
        await task?.value
        if activeRoute != nil {
            if case .failed(let error) = state {
                throw error
            }
            throw AudioRoutingError.cleanupFailed([
                "Direct Routing cleanup did not release the active route",
            ])
        }
        do {
            try deviceService.confirmRouteResourcesReleased()
        } catch let routingError as AudioRoutingError {
            state = .failed(routingError)
            throw routingError
        } catch {
            let routingError = AudioRoutingError.cleanupFailed([
                "Direct Routing resource verification failed: \(error.localizedDescription)",
            ])
            state = .failed(routingError)
            throw routingError
        }
    }

    func configurationDidChange(_ configuration: DirectRoutingConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        guard desiredRunning else { return }
        requestReconciliation(reason: "Direct Routing selection changed")
    }

    func shutdownAndWait() async -> [String] {
        guard !isShuttingDown else { return [] }
        isShuttingDown = true
        desiredRunning = false
        desiredRevision &+= 1
        workerTask?.cancel()
        let task = workerTask
        await task?.value
        workerTask = nil

        var failures: [String] = []
        if let activeRoute {
            do {
                try deviceService.stopAndDestroyRoute(sessionID: activeRoute.sessionID)
                self.activeRoute = nil
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try deviceService.confirmRouteResourcesReleased()
        } catch {
            failures.append(error.localizedDescription)
        }
        failures.append(contentsOf: deviceService.shutdown())
        state = failures.isEmpty ? .stopped : .failed(.cleanupFailed(failures))
        return failures
    }

    func revalidatePermissionIfRunning() {
        guard desiredRunning, !isShuttingDown else { return }
        requestReconciliation(reason: "Revalidating audio input permission")
    }

    func waitForIdle() async {
        await workerTask?.value
    }

    private func requestReconciliation(reason: String) {
        guard !isShuttingDown else { return }
        desiredRevision &+= 1
        let revision = desiredRevision
        let predecessor = workerTask
        predecessor?.cancel()
        report(reason)
        workerTask = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            guard !Task.isCancelled,
                  !self.isShuttingDown,
                  revision == self.desiredRevision else { return }
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
                return
            }
            self.activeRoute = nil
        }

        guard revision == desiredRevision else { return }
        guard desiredRunning else {
            do {
                try deviceService.confirmRouteResourcesReleased()
            } catch let routingError as AudioRoutingError {
                report("Direct Routing teardown failed: \(routingError.localizedDescription)")
                state = .failed(routingError)
                return
            } catch {
                let routingError = AudioRoutingError.cleanupFailed([
                    "Direct Routing resource verification failed: \(error.localizedDescription)",
                ])
                report("Direct Routing teardown failed: \(routingError.localizedDescription)")
                state = .failed(routingError)
                return
            }
            state = .stopped
            report("Direct: teardown complete")
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
                requestedBufferFrameSize: configuration.bufferSize.frameCount,
                preparationToken: UUID(),
                isRevisionCurrent: { [weak self] in
                    guard let self else { return false }
                    return revision == self.desiredRevision
                        && self.desiredRunning
                        && !self.isShuttingDown
                }
            )
            preparedRoute = route

            guard revision == desiredRevision, desiredRunning else {
                guard cleanupPreparedRoute(route, reason: "stale prepared route") else {
                    return
                }
                return
            }

            try deviceService.startRoute(
                route,
                isRevisionCurrent: { [weak self] in
                    guard let self else { return false }
                    return revision == self.desiredRevision
                        && self.desiredRunning
                        && !self.isShuttingDown
                }
            )
            guard revision == desiredRevision, desiredRunning else {
                guard cleanupPreparedRoute(route, reason: "stale started route") else {
                    return
                }
                return
            }

            activeRoute = route
            state = .running(route.route)
            report(
                "Direct Routing active: \(route.route.input.name) → \(route.route.output.name) at \(Int(route.route.nominalSampleRate)) Hz"
            )
        } catch is CancellationError {
            if let preparedRoute {
                _ = cleanupPreparedRoute(preparedRoute, reason: "cancelled route")
            }
        } catch let routingError as AudioRoutingError {
            if let preparedRoute {
                guard cleanupPreparedRoute(
                    preparedRoute,
                    reason: "failed route",
                    primaryError: routingError
                ) else {
                    return
                }
            }
            guard revision == desiredRevision else { return }
            apply(routingError)
        } catch {
            let domainError = AudioRoutingError.unexpected(
                "The audio route could not complete the requested operation"
            )
            if let preparedRoute {
                guard cleanupPreparedRoute(
                    preparedRoute,
                    reason: "unexpected route",
                    primaryError: domainError
                ) else {
                    return
                }
            }
            guard revision == desiredRevision else { return }
            report("Unexpected Direct Routing error: \(error.localizedDescription)")
            state = .failed(domainError)
        }
    }

    private func cleanupPreparedRoute(
        _ route: PreparedAudioRoute,
        reason: String,
        primaryError: AudioRoutingError? = nil
    ) -> Bool {
        do {
            try deviceService.stopAndDestroyRoute(sessionID: route.sessionID)
            if activeRoute?.sessionID == route.sessionID {
                activeRoute = nil
            }
            return true
        } catch {
            activeRoute = route
            let message = "Cleanup failed for \(reason): \(error.localizedDescription)"
            report(message)
            state = .failed(primaryError ?? .cleanupFailed([message]))
            return false
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
