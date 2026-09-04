import Combine
import Foundation
import os

private let directRoutingLogger = Logger(
    subsystem: "com.screambar.app",
    category: "DirectAudioRoutingService"
)

@MainActor
final class DirectAudioRoutingService: ObservableObject {
    private struct ActiveDeviceHardwareSignature {
        let uid: AudioDeviceUID
        let channelCount: Int
        let isAlive: Bool
        let currentNominalSampleRate: Double
    }

    private struct ActiveRouteHardwareSignature {
        let input: ActiveDeviceHardwareSignature
        let output: ActiveDeviceHardwareSignature
        let isUsingOutputFallback: Bool
    }

    private struct AutomaticBufferRouteIdentity: Equatable {
        let inputUID: AudioDeviceUID
        let outputUID: AudioDeviceUID
        let inputSampleRate: Double
        let outputSampleRate: Double

        init(route: EffectiveAudioRoute) {
            inputUID = route.input.id
            outputUID = route.output.id
            inputSampleRate = route.inputNominalSampleRate
            outputSampleRate = route.outputNominalSampleRate
        }
    }

    private static let sampleRateComparisonTolerance = 0.5
    private static let hardwareInterruptionRecoveryNanoseconds: UInt64 =
        2_000_000_000

    @Published private(set) var state: AudioRoutingState = .stopped
    @Published private(set) var desiredRunning = false

    let deviceService: CoreAudioDeviceService

    private let permissionService: any AudioInputPermissionServicing
    private let hardwareInterruptionRecoverySleep: (UInt64) async throws -> Void
    private let monotonicTimeProvider: () -> TimeInterval
    private weak var logStore: RollingLogStore?
    private var configuration = DirectRoutingConfiguration()
    private var activeRoute: PreparedAudioRoute?
    private var workerTask: Task<Void, Never>?
    private var latencyMonitorTask: Task<Void, Never>?
    private var hardwareInterruptionRecoveryTask: Task<Void, Never>?
    private var recoveringRouteSessionID: UUID?
    private var activeHardwareSignature: ActiveRouteHardwareSignature?
    private var automaticBufferOverride: UInt32?
    private var automaticBufferRouteIdentity: AutomaticBufferRouteIdentity?
    private var automaticBufferEscalationGate = AutomaticBufferEscalationGate()
    private var desiredRevision: UInt64 = 0
    private(set) var isShuttingDown = false

    init(
        logStore: RollingLogStore,
        deviceService: CoreAudioDeviceService? = nil,
        permissionService: (any AudioInputPermissionServicing)? = nil,
        hardwareInterruptionRecoverySleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        monotonicTimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.logStore = logStore
        self.deviceService = deviceService ?? CoreAudioDeviceService(logStore: logStore)
        self.permissionService = permissionService ?? AudioInputPermissionService()
        self.hardwareInterruptionRecoverySleep =
            hardwareInterruptionRecoverySleep
        self.monotonicTimeProvider = monotonicTimeProvider
        self.deviceService.onHardwareChangeObserved = { [weak self] in
            guard let self, self.desiredRunning, self.activeRoute != nil else {
                return
            }
            self.beginHardwareInterruptionRecovery()
        }
        self.deviceService.onHardwareChanged = { [weak self] in
            guard let self, self.desiredRunning else { return }
            guard self.hardwareChangeRequiresReconciliation() else {
                directRoutingLogger.debug(
                    "Ignoring hardware revision \(self.deviceService.snapshot.revision): the effective Direct Routing stream contract is unchanged"
                )
                return
            }
            self.discardAutomaticBufferOverrideIfRouteChanged()
            self.requestReconciliation(reason: "Direct Routing rebuilding after hardware change")
        }
    }

    func start(configuration: DirectRoutingConfiguration) {
        guard !isShuttingDown else {
            state = .failed(.serviceShuttingDown)
            return
        }
        self.configuration = configuration
        resetAutomaticBufferOverride()
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
        let routeConfigurationChanged =
            self.configuration.inputSelection != configuration.inputSelection
            || self.configuration.outputSelection != configuration.outputSelection
            || self.configuration.bufferSize != configuration.bufferSize
        let sensitivityChanged = self.configuration.automaticSensitivity
            != configuration.automaticSensitivity
        self.configuration = configuration
        automaticBufferEscalationGate.reset()
        guard routeConfigurationChanged else {
            if desiredRunning, sensitivityChanged,
               configuration.bufferSize == .automatic {
                if let sessionID = activeRoute?.sessionID {
                    deviceService.checkpointRouteStability(
                        sessionID: sessionID
                    )
                }
                report(
                    "Automatic buffer sensitivity changed to \(configuration.automaticSensitivity.label)"
                )
            }
            return
        }
        resetAutomaticBufferOverride()
        guard desiredRunning else { return }
        requestReconciliation(reason: "Direct Routing selection changed")
    }

    func shutdownAndWait() async -> [String] {
        guard !isShuttingDown else { return [] }
        isShuttingDown = true
        desiredRunning = false
        desiredRevision &+= 1
        workerTask?.cancel()
        latencyMonitorTask?.cancel()
        latencyMonitorTask = nil
        cancelHardwareInterruptionRecovery()
        let task = workerTask
        await task?.value
        workerTask = nil

        var failures: [String] = []
        if let activeRoute {
            do {
                try deviceService.stopAndDestroyRoute(sessionID: activeRoute.sessionID)
                self.activeRoute = nil
                activeHardwareSignature = nil
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
        cancelHardwareInterruptionRecovery()
        automaticBufferEscalationGate.reset()
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
        latencyMonitorTask?.cancel()
        latencyMonitorTask = nil
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
            activeHardwareSignature = nil
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
                requestedBufferFrameSize: configuration.bufferSize.frameCount
                    ?? automaticBufferOverride,
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
            activeHardwareSignature = makeActiveHardwareSignature(
                in: deviceService.snapshot
            )
            if automaticBufferOverride != nil {
                automaticBufferRouteIdentity = AutomaticBufferRouteIdentity(
                    route: route.route
                )
            }
            state = .running(route.route)
            let routeLogDescription = routeDescription(route.route)
                + convertedRouteBufferDiagnostic(route.route)
            report("Direct Routing active: \(routeLogDescription)")
            report(
                "Direct Routing formats: \(route.route.hardwareFormatDiagnosticDescription)"
            )
            startLatencyMonitor(for: route)
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
            if retryAutomaticBufferAfterPreparationFailure(routingError) {
                return
            }
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

    private func startLatencyMonitor(for preparedRoute: PreparedAudioRoute) {
        latencyMonitorTask?.cancel()
        automaticBufferEscalationGate.reset()
        latencyMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    self?.report(
                        "Direct Routing latency monitor failed: \(error.localizedDescription)"
                    )
                    return
                }
                guard let self,
                      self.desiredRunning,
                      self.activeRoute?.sessionID == preparedRoute.sessionID,
                      let latency = self.deviceService.routeLatency(
                          sessionID: preparedRoute.sessionID
                      ) else {
                    return
                }

                let escalationEvaluation: AutomaticBufferEscalationEvaluation
                if self.recoveringRouteSessionID == preparedRoute.sessionID {
                    escalationEvaluation = AutomaticBufferEscalationEvaluation(
                        shouldEscalate: false,
                        newlyObservedIncidentCount: 0,
                        recentIncidentCount: 0
                    )
                } else {
                    let sensitivity = self.configuration.bufferSize == .automatic
                        ? self.configuration.automaticSensitivity
                        : .strict
                    escalationEvaluation = self.automaticBufferEscalationGate
                        .evaluate(
                            sensitivity: sensitivity,
                            routeRequiresEscalation:
                                latency.requiresBufferEscalation,
                            cumulativeIncidentCount:
                                latency.bufferEscalationIncidentCount,
                            monotonicTime: self.monotonicTimeProvider()
                        )
                    if sensitivity == .relaxed,
                       escalationEvaluation.newlyObservedIncidentCount > 0,
                       !escalationEvaluation.shouldEscalate {
                        self.report(
                            "Relaxed automatic buffer sensitivity tolerated \(escalationEvaluation.recentIncidentCount) of 3 incidents in 10 seconds"
                        )
                    }
                }

                if escalationEvaluation.shouldEscalate {
                    if self.configuration.bufferSize == .automatic,
                       let nextFrameCount = self.nextAutomaticBufferFrameSize(
                           after: self.activeRoute?.route.bufferFrameSize
                       ) {
                        self.automaticBufferOverride = nextFrameCount
                        self.automaticBufferRouteIdentity =
                            AutomaticBufferRouteIdentity(route: preparedRoute.route)
                        let reasonSuffix = latency.bufferEscalationReason.map {
                            " (\($0))"
                        } ?? ""
                        self.report(
                            "Direct Routing increasing the automatic buffer to \(nextFrameCount) frames after a runtime disruption\(reasonSuffix)"
                        )
                        self.requestReconciliation(
                            reason: "Direct Routing rebuilding with a safer buffer"
                        )
                        return
                    }
                    self.stopUnstableRoute(
                        preparedRoute,
                        latency: latency
                    )
                    return
                }

                guard var activeRoute = self.activeRoute else { return }
                let currentRoute = activeRoute.route
                let updatedRoute = EffectiveAudioRoute(
                    input: currentRoute.input,
                    output: currentRoute.output,
                    sampleRatePlan: currentRoute.sampleRatePlan,
                    isUsingOutputFallback: currentRoute.isUsingOutputFallback,
                    bufferFrameSize: currentRoute.bufferFrameSize,
                    estimatedApplicationLatencySeconds:
                        latency.estimatedApplicationSeconds,
                    maximumApplicationLatencySeconds:
                        latency.maximumApplicationSeconds,
                    isLowLatency: latency.isLowLatency
                )
                guard updatedRoute != currentRoute else { continue }
                activeRoute = PreparedAudioRoute(
                    sessionID: activeRoute.sessionID,
                    route: updatedRoute
                )
                self.activeRoute = activeRoute
                self.state = .running(updatedRoute)
            }
        }
    }

    private func nextAutomaticBufferFrameSize(after current: UInt32?) -> UInt32? {
        let snapshot = deviceService.snapshot
        guard let input = effectiveInputDevice(in: snapshot),
              let output = effectiveOutputDevice(in: snapshot) else {
            return nil
        }
        return AsyncSRCLowLatencyPolicy.nextSupportedBufferFrameSize(
            after: current,
            input: input,
            output: output
        )
    }

    private func resetAutomaticBufferOverride() {
        automaticBufferOverride = nil
        automaticBufferRouteIdentity = nil
    }

    private func discardAutomaticBufferOverrideIfRouteChanged() {
        guard automaticBufferOverride != nil else { return }
        guard let identity = automaticBufferRouteIdentity else {
            resetAutomaticBufferOverride()
            return
        }
        let snapshot = deviceService.snapshot
        guard let input = effectiveInputDevice(in: snapshot),
              let output = effectiveOutputDevice(in: snapshot),
              input.id == identity.inputUID,
              output.id == identity.outputUID,
              sampleRatesMatch(
                  input.currentNominalSampleRate,
                  identity.inputSampleRate
              ),
              sampleRatesMatch(
                  output.currentNominalSampleRate,
                  identity.outputSampleRate
              ),
              let automaticBufferOverride,
              AsyncSRCLowLatencyPolicy.supportsBufferFrameSize(
                  automaticBufferOverride,
                  input: input,
                  output: output
              ) else {
            resetAutomaticBufferOverride()
            return
        }
    }

    private func effectiveInputDevice(
        in snapshot: AudioHardwareSnapshot
    ) -> AudioDeviceDescriptor? {
        switch configuration.inputSelection {
        case .systemDefault:
            guard let uid = snapshot.defaultInputUID else { return nil }
            return snapshot.device(withUID: uid)
        case .device(let uid, _):
            return snapshot.device(withUID: uid)
        }
    }

    private func effectiveOutputDevice(
        in snapshot: AudioHardwareSnapshot
    ) -> AudioDeviceDescriptor? {
        effectiveOutputResolution(in: snapshot)?.device
    }

    private func sampleRatesMatch(_ first: Double, _ second: Double) -> Bool {
        abs(first - second) <= Self.sampleRateComparisonTolerance
    }

    private func hardwareChangeRequiresReconciliation() -> Bool {
        guard activeRoute != nil else {
            return true
        }
        guard let activeHardwareSignature,
              let currentHardwareSignature = makeActiveHardwareSignature(
                  in: deviceService.snapshot
              ) else {
            return true
        }
        return !hardwareSignaturesMatch(
            activeHardwareSignature,
            currentHardwareSignature
        )
    }

    private func beginHardwareInterruptionRecovery() {
        guard let sessionID = activeRoute?.sessionID else { return }
        hardwareInterruptionRecoveryTask?.cancel()
        automaticBufferEscalationGate.reset()
        recoveringRouteSessionID = sessionID
        deviceService.checkpointRouteStability(sessionID: sessionID)
        hardwareInterruptionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.hardwareInterruptionRecoverySleep(
                    Self.hardwareInterruptionRecoveryNanoseconds
                )
            } catch is CancellationError {
                return
            } catch {
                self.report(
                    "Direct Routing hardware recovery monitor failed: \(error.localizedDescription)"
                )
                self.recoveringRouteSessionID = nil
                self.hardwareInterruptionRecoveryTask = nil
                return
            }
            guard self.desiredRunning,
                  self.activeRoute?.sessionID == sessionID else {
                return
            }
            self.deviceService.checkpointRouteStability(sessionID: sessionID)
            self.automaticBufferEscalationGate.reset()
            self.recoveringRouteSessionID = nil
            self.hardwareInterruptionRecoveryTask = nil
            directRoutingLogger.debug(
                "Direct Routing resumed stability monitoring after an unrelated CoreAudio hardware interruption"
            )
        }
    }

    private func cancelHardwareInterruptionRecovery() {
        hardwareInterruptionRecoveryTask?.cancel()
        hardwareInterruptionRecoveryTask = nil
        recoveringRouteSessionID = nil
    }

    private func makeActiveHardwareSignature(
        in snapshot: AudioHardwareSnapshot
    ) -> ActiveRouteHardwareSignature? {
        guard let input = effectiveInputDevice(in: snapshot),
              input.supportsInput,
              input.isAlive,
              let outputResolution = effectiveOutputResolution(in: snapshot),
              outputResolution.device.supportsOutput,
              outputResolution.device.isAlive else {
            return nil
        }
        return ActiveRouteHardwareSignature(
            input: makeDeviceHardwareSignature(
                input,
                channelCount: input.inputChannelCount
            ),
            output: makeDeviceHardwareSignature(
                outputResolution.device,
                channelCount: outputResolution.device.outputChannelCount
            ),
            isUsingOutputFallback: outputResolution.isUsingFallback
        )
    }

    private func makeDeviceHardwareSignature(
        _ device: AudioDeviceDescriptor,
        channelCount: Int
    ) -> ActiveDeviceHardwareSignature {
        // Buffer metadata and advertised capability ranges may change during an
        // unrelated CoreAudio inventory update. They do not invalidate an
        // already-running stream. Rebuild only when the effective stream
        // contract itself changes; explicit buffer selections are reconciled
        // through configurationDidChange(_:).
        ActiveDeviceHardwareSignature(
            uid: device.id,
            channelCount: channelCount,
            isAlive: device.isAlive,
            currentNominalSampleRate: device.currentNominalSampleRate
        )
    }

    private func hardwareSignaturesMatch(
        _ first: ActiveRouteHardwareSignature,
        _ second: ActiveRouteHardwareSignature
    ) -> Bool {
        first.isUsingOutputFallback == second.isUsingOutputFallback
            && deviceHardwareSignaturesMatch(first.input, second.input)
            && deviceHardwareSignaturesMatch(first.output, second.output)
    }

    private func deviceHardwareSignaturesMatch(
        _ first: ActiveDeviceHardwareSignature,
        _ second: ActiveDeviceHardwareSignature
    ) -> Bool {
        first.uid == second.uid
            && first.channelCount == second.channelCount
            && first.isAlive == second.isAlive
            && sampleRatesMatch(
                first.currentNominalSampleRate,
                second.currentNominalSampleRate
            )
    }

    private func effectiveOutputResolution(
        in snapshot: AudioHardwareSnapshot
    ) -> (device: AudioDeviceDescriptor, isUsingFallback: Bool)? {
        switch configuration.outputSelection {
        case .systemDefault:
            guard let uid = snapshot.defaultOutputUID,
                  let output = snapshot.device(withUID: uid) else {
                return nil
            }
            return (output, false)
        case .device(let uid, _):
            if let selectedDevice = snapshot.device(withUID: uid) {
                return (selectedDevice, false)
            }
            guard let defaultUID = snapshot.defaultOutputUID,
                  let fallback = snapshot.device(withUID: defaultUID) else {
                return nil
            }
            return (fallback, true)
        }
    }

    private func stopUnstableRoute(
        _ preparedRoute: PreparedAudioRoute,
        latency: CoreAudioRouteLatency
    ) {
        let route = preparedRoute.route
        let stabilityError = AudioRoutingError.latencyStabilityLimitExceeded(
            RoutingLatencyStabilityContext(
                inputUID: route.input.id,
                outputUID: route.output.id,
                bufferFrameCount: route.bufferFrameSize,
                estimatedApplicationLatencySeconds:
                    latency.estimatedApplicationSeconds
            )
        )
        desiredRunning = false
        desiredRevision &+= 1
        workerTask?.cancel()
        state = .stopping
        let escalationReason = latency.bufferEscalationReason
            ?? "unspecified runtime instability"
        let stopMessage: String
        if let explicitFrameCount = configuration.bufferSize.frameCount {
            stopMessage = String(
                format: "Direct Routing stopping because the explicit %u-frame buffer became unstable (app latency: %.1f ms, maximum: %.1f ms, reason: %@)",
                explicitFrameCount,
                latency.estimatedApplicationSeconds * 1_000,
                latency.maximumApplicationSeconds * 1_000,
                escalationReason
            )
        } else {
            let bufferTierDescription = route.bufferFrameSize.map {
                "\($0) frames"
            } ?? "system default"
            stopMessage = String(
                format: "Direct Routing stopping after the automatic buffer ladder was exhausted (buffer tier: %@, app latency: %.1f ms, maximum: %.1f ms, reason: %@)",
                bufferTierDescription,
                latency.estimatedApplicationSeconds * 1_000,
                latency.maximumApplicationSeconds * 1_000,
                escalationReason
            )
        }
        report(stopMessage)
        do {
            try deviceService.stopAndDestroyRoute(
                sessionID: preparedRoute.sessionID
            )
            activeRoute = nil
            activeHardwareSignature = nil
            try deviceService.confirmRouteResourcesReleased()
            state = .failed(stabilityError)
            report(stabilityError.localizedDescription)
        } catch {
            state = .failed(.cleanupFailed([error.localizedDescription]))
            report(
                "Direct Routing cleanup failed after a stability error: \(error.localizedDescription)"
            )
        }
    }

    private func retryAutomaticBufferAfterPreparationFailure(
        _ error: AudioRoutingError
    ) -> Bool {
        guard configuration.bufferSize == .automatic else { return false }
        let failedFrameCount: UInt32
        switch error {
        case .unsupportedBufferFrameSize(let context):
            failedFrameCount = context.requestedFrameCount
        case .bufferFrameSizeConfigurationFailed(let context):
            failedFrameCount = context.requestedFrameCount
        default:
            return false
        }
        guard let nextFrameCount = nextAutomaticBufferFrameSize(
            after: failedFrameCount
        ) else {
            return false
        }
        automaticBufferOverride = nextFrameCount
        report(
            "Direct Routing could not use \(failedFrameCount) frames; trying \(nextFrameCount) frames"
        )
        requestReconciliation(
            reason: "Direct Routing rebuilding with the next supported buffer"
        )
        return true
    }

    private func routeDescription(_ route: EffectiveAudioRoute) -> String {
        if route.usesSampleRateConversion {
            let latencyDescription: String
            if let latencySeconds = route.estimatedApplicationLatencySeconds {
                let latencyModeDescription: String
                if !route.isLowLatency {
                    latencyModeDescription = "low-latency fallback"
                } else if latencySeconds
                    <= AsyncSRCBufferSizing.preferredApplicationLatencySeconds {
                    latencyModeDescription = "preferred low latency"
                } else {
                    latencyModeDescription = "stable low latency"
                }
                latencyDescription = String(
                    format: ", app latency ≈ %.1f ms, %@",
                    latencySeconds * 1_000,
                    latencyModeDescription
                )
            } else {
                latencyDescription = ""
            }
            return "\(route.input.name) → \(route.output.name) at \(Int(route.inputNominalSampleRate)) → \(Int(route.outputNominalSampleRate)) Hz (converted\(latencyDescription))"
        }
        return "\(route.input.name) → \(route.output.name) at \(Int(route.nominalSampleRate)) Hz"
    }

    private func convertedRouteBufferDiagnostic(
        _ route: EffectiveAudioRoute
    ) -> String {
        guard route.usesSampleRateConversion else { return "" }
        let policyDescription = configuration.bufferSize.frameCount.map {
            "explicit \($0) frames"
        } ?? "automatic"
        let effectiveTierDescription = route.bufferFrameSize.map {
            "\($0) frames"
        } ?? "system default"
        let sensitivityDescription = configuration.bufferSize == .automatic
            ? ", sensitivity: \(configuration.automaticSensitivity.label)"
            : ""
        return ", buffer policy: \(policyDescription), effective tier: \(effectiveTierDescription)\(sensitivityDescription)"
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
                activeHardwareSignature = nil
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
