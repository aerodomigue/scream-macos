import Combine
import Foundation
import os

private let coreAudioServiceLogger = Logger(
    subsystem: "com.screambar.app",
    category: "CoreAudioDeviceService"
)

struct CoreAudioServiceTiming {
    let sleep: (UInt64) async throws -> Void

    static let live = CoreAudioServiceTiming(
        sleep: { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}

@MainActor
final class CoreAudioDeviceService: ObservableObject {
    private struct PreparationSignature {
        let inputUID: AudioDeviceUID
        let outputUID: AudioDeviceUID
        let nominalSampleRate: Double
        let inputRanges: [NominalSampleRateRange]
        let outputRanges: [NominalSampleRateRange]
    }

    private struct PreparationWaiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private static let hardwareChangeDebounceNanoseconds: UInt64 = 200_000_000
    private static let ratePollNanoseconds: UInt64 = 20_000_000
    private static let rateConfigurationTimeoutSeconds = 2.0

    @Published private(set) var snapshot = AudioHardwareSnapshot(
        revision: 0,
        devices: [],
        defaultInputUID: nil,
        defaultOutputUID: nil
    )

    var onHardwareChanged: (() -> Void)?

    private let backend: any CoreAudioBackend
    private let timing: CoreAudioServiceTiming
    private weak var logStore: RollingLogStore?
    private var revision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var activePreparationToken: UUID?
    private var preparationWaiters: [PreparationWaiter] = []
    private var hasDeferredHardwareChange = false
    private var pendingCleanupSessionIDs = Set<UUID>()
    private(set) var isShuttingDown = false

    init(
        logStore: RollingLogStore,
        backend: (any CoreAudioBackend)? = nil,
        timing: CoreAudioServiceTiming = .live
    ) {
        self.logStore = logStore
        self.backend = backend ?? CoreAudioBackendFactory.makeBackend()
        self.timing = timing
        self.backend.onHardwareChanged = { [weak self] in
            self?.scheduleHardwareRefresh()
        }

        do {
            try self.backend.startMonitoring()
            try refreshSnapshot(notifyRoute: false)
        } catch {
            report("Failed to initialize CoreAudio inventory: \(error.localizedDescription)")
        }
    }

    var inputDevices: [AudioDeviceDescriptor] {
        snapshot.inputDevices
    }

    var outputDevices: [AudioDeviceDescriptor] {
        snapshot.outputDevices
    }

    func prepareRoute(
        inputSelection: AudioDeviceSelection,
        outputSelection: AudioDeviceSelection,
        requestedBufferFrameSize: UInt32? = nil,
        preparationToken: UUID = UUID(),
        isRevisionCurrent: @escaping () -> Bool = { true }
    ) async throws -> PreparedAudioRoute {
        try await acquirePreparationOwnership(preparationToken)
        defer { releasePreparationOwnership(preparationToken) }
        try validatePreparationOwnership(
            preparationToken,
            isRevisionCurrent: isRevisionCurrent
        )
        try retryPendingRouteCleanups()

        try refreshSnapshot(notifyRoute: false)
        let resolution = try resolveRoute(
            inputSelection: inputSelection,
            outputSelection: outputSelection
        )
        let inputDevice = resolution.input
        let outputDevice = resolution.output
        let nominalSampleRate = try NominalSampleRateNegotiator.negotiate(
            inputRanges: inputDevice.supportedNominalSampleRates,
            outputRanges: outputDevice.supportedNominalSampleRates,
            outputCurrentRate: outputDevice.currentNominalSampleRate,
            inputUID: inputDevice.id,
            outputUID: outputDevice.id
        )
        if let requestedBufferFrameSize {
            try BufferFrameSizeValidator.validate(
                requestedFrameCount: requestedBufferFrameSize,
                input: inputDevice,
                output: outputDevice
            )
        }
        let expectedSignature = PreparationSignature(
            inputUID: inputDevice.id,
            outputUID: outputDevice.id,
            nominalSampleRate: nominalSampleRate,
            inputRanges: inputDevice.supportedNominalSampleRates,
            outputRanges: outputDevice.supportedNominalSampleRates
        )

        let validateOwnership = { [weak self] in
            guard let self else { throw CancellationError() }
            try self.validatePreparationOwnership(
                preparationToken,
                isRevisionCurrent: isRevisionCurrent
            )
        }

        try await configureAndVerifySampleRate(
            nominalSampleRate,
            for: outputDevice.id,
            operation: "output",
            validateOwnership: validateOwnership
        )
        try validateOwnership()
        if inputDevice.id != outputDevice.id {
            try await configureAndVerifySampleRate(
                nominalSampleRate,
                for: inputDevice.id,
                operation: "input",
                validateOwnership: validateOwnership
            )
        }

        try validateOwnership()
        guard try backend.isAlive(uid: inputDevice.id) else {
            throw AudioRoutingError.inputDeviceUnavailable(inputDevice.id)
        }
        guard try backend.isAlive(uid: outputDevice.id) else {
            throw AudioRoutingError.outputDeviceUnavailable(outputDevice.id)
        }

        let sessionID: UUID
        do {
            try validateOwnership()
            sessionID = try backend.prepareRoute(
                input: inputDevice,
                output: outputDevice,
                nominalSampleRate: nominalSampleRate,
                requestedBufferFrameSize: requestedBufferFrameSize,
                validateOwnership: validateOwnership
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as LegacyRouteFailure {
            throw map(
                failure,
                input: inputDevice,
                output: outputDevice,
                nominalSampleRate: nominalSampleRate
            )
        } catch let failure as AUHALSetupFailure {
            throw AudioRoutingError.auHALConfigurationFailed(
                stage: failure.stage,
                context: makeAUHALContext(
                    input: inputDevice,
                    output: outputDevice,
                    nominalSampleRate: nominalSampleRate
                )
            )
        } catch {
            report("CoreAudio route preparation failed: \(error.localizedDescription)")
            throw AudioRoutingError.aggregateCreationFailed(
                makeAggregateContext(
                    input: inputDevice,
                    output: outputDevice,
                    nominalSampleRate: nominalSampleRate
                )
            )
        }

        do {
            try validateOwnership()
            try backend.rebuildListeners()
            try refreshSnapshot(notifyRoute: false)
            try validateOwnership()
            try validateFinalRoute(
                inputSelection: inputSelection,
                outputSelection: outputSelection,
                expectedSignature: expectedSignature
            )
        } catch {
            let cleanupFailures = backend.stopAndDestroyRoute(sessionID: sessionID)
            if cleanupFailures.isEmpty {
                pendingCleanupSessionIDs.remove(sessionID)
            } else {
                pendingCleanupSessionIDs.insert(sessionID)
                cleanupFailures.forEach {
                    report("Post-validation cleanup failed: \($0)")
                }
            }
            if error is CancellationError {
                throw error
            }
            if let routingError = error as? AudioRoutingError {
                throw routingError
            }
            report("Final route validation failed: \(error.localizedDescription)")
            throw AudioRoutingError.finalRouteValidationFailed(
                makeAUHALContext(
                    input: inputDevice,
                    output: outputDevice,
                    nominalSampleRate: nominalSampleRate
                )
            )
        }

        return PreparedAudioRoute(
            sessionID: sessionID,
            route: EffectiveAudioRoute(
                input: inputDevice,
                output: outputDevice,
                nominalSampleRate: nominalSampleRate,
                isUsingOutputFallback: resolution.isUsingOutputFallback
            )
        )
    }

    func startRoute(
        _ preparedRoute: PreparedAudioRoute,
        isRevisionCurrent: () -> Bool = { true }
    ) throws {
        guard !isShuttingDown, isRevisionCurrent(), !Task.isCancelled else {
            throw CancellationError()
        }
        do {
            try backend.startRoute(sessionID: preparedRoute.sessionID)
        } catch let failure as AUHALSetupFailure {
            report("AUHAL start failed with OSStatus \(failure.status)")
            throw AudioRoutingError.auHALStartFailed(
                makeAUHALContext(
                    input: preparedRoute.route.input,
                    output: preparedRoute.route.output,
                    nominalSampleRate: preparedRoute.route.nominalSampleRate
                )
            )
        } catch {
            report("AUHAL start failed: \(error.localizedDescription)")
            throw AudioRoutingError.auHALStartFailed(
                makeAUHALContext(
                    input: preparedRoute.route.input,
                    output: preparedRoute.route.output,
                    nominalSampleRate: preparedRoute.route.nominalSampleRate
                )
            )
        }
    }

    func stopAndDestroyRoute(sessionID: UUID) throws {
        let cleanupFailures = backend.stopAndDestroyRoute(sessionID: sessionID)
        guard cleanupFailures.isEmpty else {
            pendingCleanupSessionIDs.insert(sessionID)
            cleanupFailures.forEach { report($0) }
            throw AudioRoutingError.cleanupFailed(cleanupFailures)
        }
        pendingCleanupSessionIDs.remove(sessionID)
    }

    @discardableResult
    func shutdown() -> [String] {
        guard !isShuttingDown else { return [] }
        isShuttingDown = true
        refreshTask?.cancel()
        refreshTask = nil
        let waitingContinuations = preparationWaiters.map(\.continuation)
        preparationWaiters.removeAll()
        waitingContinuations.forEach { $0.resume() }
        let cleanupFailures = backend.shutdown()
        cleanupFailures.forEach { report($0) }
        return cleanupFailures
    }

    private func resolveRoute(
        inputSelection: AudioDeviceSelection,
        outputSelection: AudioDeviceSelection
    ) throws -> (
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        isUsingOutputFallback: Bool
    ) {
        let inputDevice: AudioDeviceDescriptor
        switch inputSelection {
        case .systemDefault:
            guard let defaultInputUID = snapshot.defaultInputUID,
                  let defaultInput = snapshot.device(withUID: defaultInputUID),
                  defaultInput.supportsInput,
                  defaultInput.isAlive else {
                throw AudioRoutingError.inputDeviceUnavailable(snapshot.defaultInputUID)
            }
            inputDevice = defaultInput
        case .device(let uid, _):
            guard let selectedInput = snapshot.device(withUID: uid),
                  selectedInput.supportsInput,
                  selectedInput.isAlive else {
                throw AudioRoutingError.inputDeviceUnavailable(uid)
            }
            inputDevice = selectedInput
        }

        let outputDevice: AudioDeviceDescriptor
        let isUsingOutputFallback: Bool
        switch outputSelection {
        case .systemDefault:
            guard let defaultOutputUID = snapshot.defaultOutputUID,
                  let defaultOutput = snapshot.device(withUID: defaultOutputUID),
                  defaultOutput.supportsOutput,
                  defaultOutput.isAlive else {
                throw AudioRoutingError.outputDeviceUnavailable(snapshot.defaultOutputUID)
            }
            outputDevice = defaultOutput
            isUsingOutputFallback = false
        case .device(let uid, _):
            if let selectedOutput = snapshot.device(withUID: uid) {
                guard selectedOutput.supportsOutput, selectedOutput.isAlive else {
                    throw AudioRoutingError.outputDeviceUnavailable(uid)
                }
                outputDevice = selectedOutput
                isUsingOutputFallback = false
            } else {
                guard let defaultOutputUID = snapshot.defaultOutputUID,
                      let defaultOutput = snapshot.device(withUID: defaultOutputUID),
                      defaultOutput.supportsOutput,
                      defaultOutput.isAlive else {
                    throw AudioRoutingError.outputDeviceUnavailable(uid)
                }
                outputDevice = defaultOutput
                isUsingOutputFallback = true
            }
        }

        return (inputDevice, outputDevice, isUsingOutputFallback)
    }

    private func configureAndVerifySampleRate(
        _ sampleRate: Double,
        for uid: AudioDeviceUID,
        operation: String,
        validateOwnership: () throws -> Void
    ) async throws {
        let currentRate: Double
        do {
            currentRate = try backend.currentNominalSampleRate(for: uid)
        } catch {
            report("Failed to read \(operation) nominal sample rate: \(error.localizedDescription)")
            throw AudioRoutingError.sampleRateConfigurationFailed(
                SampleRateConfigurationContext(
                    deviceUID: uid,
                    requestedRate: sampleRate,
                    observedRate: nil,
                    operation: "read \(operation)"
                )
            )
        }

        guard !NominalSampleRateNegotiator.ratesMatch(currentRate, sampleRate) else { return }

        try validateOwnership()
        do {
            try backend.setNominalSampleRate(sampleRate, for: uid)
        } catch {
            report("Failed to set \(operation) nominal sample rate: \(error.localizedDescription)")
            throw AudioRoutingError.sampleRateConfigurationFailed(
                SampleRateConfigurationContext(
                    deviceUID: uid,
                    requestedRate: sampleRate,
                    observedRate: currentRate,
                    operation: "set \(operation)"
                )
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.rateConfigurationTimeoutSeconds))
        var observedRate = currentRate
        while clock.now < deadline {
            do {
                observedRate = try backend.currentNominalSampleRate(for: uid)
            } catch {
                report("Failed sample-rate read-back for \(operation): \(error.localizedDescription)")
                throw AudioRoutingError.sampleRateConfigurationFailed(
                    SampleRateConfigurationContext(
                        deviceUID: uid,
                        requestedRate: sampleRate,
                        observedRate: nil,
                        operation: "read-back \(operation)"
                    )
                )
            }
            if NominalSampleRateNegotiator.ratesMatch(observedRate, sampleRate) {
                return
            }
            do {
                try await timing.sleep(Self.ratePollNanoseconds)
                try validateOwnership()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report("Unexpected sample-rate wait failure: \(error.localizedDescription)")
                throw error
            }
        }

        throw AudioRoutingError.sampleRateConfigurationFailed(
            SampleRateConfigurationContext(
                deviceUID: uid,
                requestedRate: sampleRate,
                observedRate: observedRate,
                operation: "verify \(operation)"
            )
        )
    }

    private func scheduleHardwareRefresh() {
        guard !isShuttingDown else { return }
        if activePreparationToken != nil {
            hasDeferredHardwareChange = true
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await self?.timing.sleep(Self.hardwareChangeDebounceNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                self?.report("Unexpected hardware debounce failure: \(error.localizedDescription)")
                return
            }
            guard let self else { return }
            guard !self.isShuttingDown else { return }
            guard self.activePreparationToken == nil else {
                self.hasDeferredHardwareChange = true
                return
            }
            do {
                try self.backend.rebuildListeners()
                try self.refreshSnapshot(notifyRoute: true)
            } catch {
                self.report("Failed to refresh CoreAudio inventory: \(error.localizedDescription)")
            }
        }
    }

    private func validateFinalRoute(
        inputSelection: AudioDeviceSelection,
        outputSelection: AudioDeviceSelection,
        expectedSignature: PreparationSignature
    ) throws {
        let context = AUHALContext(
            inputUID: expectedSignature.inputUID,
            outputUID: expectedSignature.outputUID,
            nominalSampleRate: expectedSignature.nominalSampleRate
        )
        let resolution: (
            input: AudioDeviceDescriptor,
            output: AudioDeviceDescriptor,
            isUsingOutputFallback: Bool
        )
        do {
            resolution = try resolveRoute(
                inputSelection: inputSelection,
                outputSelection: outputSelection
            )
        } catch {
            throw AudioRoutingError.finalRouteValidationFailed(context)
        }
        let inputRanges = NominalSampleRateNegotiator.normalizedRanges(
            resolution.input.supportedNominalSampleRates
        )
        let outputRanges = NominalSampleRateNegotiator.normalizedRanges(
            resolution.output.supportedNominalSampleRates
        )
        let expectedInputRanges = NominalSampleRateNegotiator.normalizedRanges(
            expectedSignature.inputRanges
        )
        let expectedOutputRanges = NominalSampleRateNegotiator.normalizedRanges(
            expectedSignature.outputRanges
        )
        guard resolution.input.id == expectedSignature.inputUID,
              resolution.output.id == expectedSignature.outputUID,
              NominalSampleRateNegotiator.ratesMatch(
                  resolution.input.currentNominalSampleRate,
                  expectedSignature.nominalSampleRate
              ),
              NominalSampleRateNegotiator.ratesMatch(
                  resolution.output.currentNominalSampleRate,
                  expectedSignature.nominalSampleRate
              ),
              inputRanges == expectedInputRanges,
              outputRanges == expectedOutputRanges else {
            throw AudioRoutingError.finalRouteValidationFailed(context)
        }
    }

    private func acquirePreparationOwnership(_ token: UUID) async throws {
        guard !isShuttingDown else {
            throw AudioRoutingError.serviceShuttingDown
        }
        if activePreparationToken == nil {
            activePreparationToken = token
            return
        }
        await withCheckedContinuation { continuation in
            preparationWaiters.append(
                PreparationWaiter(token: token, continuation: continuation)
            )
        }
        do {
            try Task.checkCancellation()
            guard !isShuttingDown, activePreparationToken == token else {
                throw AudioRoutingError.serviceShuttingDown
            }
        } catch {
            releasePreparationOwnership(token)
            throw error
        }
    }

    private func releasePreparationOwnership(_ token: UUID) {
        guard activePreparationToken == token else { return }
        if isShuttingDown {
            activePreparationToken = nil
            return
        }
        if !preparationWaiters.isEmpty {
            let nextWaiter = preparationWaiters.removeFirst()
            activePreparationToken = nextWaiter.token
            nextWaiter.continuation.resume()
            return
        }
        activePreparationToken = nil
        if hasDeferredHardwareChange {
            hasDeferredHardwareChange = false
            scheduleHardwareRefresh()
        }
    }

    private func validatePreparationOwnership(
        _ token: UUID,
        isRevisionCurrent: () -> Bool
    ) throws {
        try Task.checkCancellation()
        guard !isShuttingDown else {
            throw AudioRoutingError.serviceShuttingDown
        }
        guard activePreparationToken == token, isRevisionCurrent() else {
            throw CancellationError()
        }
    }

    private func retryPendingRouteCleanups() throws {
        var failures: [String] = []
        for sessionID in Array(pendingCleanupSessionIDs) {
            let cleanupFailures = backend.stopAndDestroyRoute(sessionID: sessionID)
            if cleanupFailures.isEmpty {
                pendingCleanupSessionIDs.remove(sessionID)
            } else {
                failures.append(contentsOf: cleanupFailures)
            }
        }
        guard failures.isEmpty else {
            failures.forEach { report($0) }
            throw AudioRoutingError.cleanupFailed(failures)
        }
    }

    @discardableResult
    private func refreshSnapshot(notifyRoute: Bool) throws -> Bool {
        let previousSnapshot = snapshot
        revision &+= 1
        let refreshedSnapshot = try backend.makeSnapshot(revision: revision)
        let snapshotChanged = !hardwareStateMatches(previousSnapshot, refreshedSnapshot)
        snapshot = refreshedSnapshot
        if notifyRoute && snapshotChanged {
            reportDefaultOutputChange(
                from: previousSnapshot,
                to: refreshedSnapshot
            )
            onHardwareChanged?()
        }
        return snapshotChanged
    }

    private func hardwareStateMatches(
        _ first: AudioHardwareSnapshot,
        _ second: AudioHardwareSnapshot
    ) -> Bool {
        first.devices == second.devices
            && first.defaultInputUID == second.defaultInputUID
            && first.defaultOutputUID == second.defaultOutputUID
    }

    private func reportDefaultOutputChange(
        from previousSnapshot: AudioHardwareSnapshot,
        to refreshedSnapshot: AudioHardwareSnapshot
    ) {
        guard previousSnapshot.defaultOutputUID != refreshedSnapshot.defaultOutputUID else {
            return
        }
        let previousName = deviceName(
            for: previousSnapshot.defaultOutputUID,
            in: previousSnapshot
        )
        let refreshedName = deviceName(
            for: refreshedSnapshot.defaultOutputUID,
            in: refreshedSnapshot
        )
        inform("Default output changed: \(previousName) → \(refreshedName)")
    }

    private func deviceName(
        for uid: AudioDeviceUID?,
        in snapshot: AudioHardwareSnapshot
    ) -> String {
        guard let uid else { return "No default output" }
        return snapshot.devices.first { $0.id == uid }?.name ?? "Unavailable output"
    }

    private func map(
        _ failure: LegacyRouteFailure,
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double
    ) -> AudioRoutingError {
        switch failure {
        case .bufferFrameSizeConfiguration(let context):
            report(
                "Buffer frame size configuration failed for \(context.deviceUID.rawValue): \(context.operation)"
            )
            return .bufferFrameSizeConfigurationFailed(context)
        case .aggregateUnsupported(let status):
            report("Aggregate device unsupported: OSStatus \(status)")
            return .aggregateDeviceUnsupported(
                makeAggregateContext(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate
                )
            )
        case .aggregateCreation(let status):
            report("Aggregate creation failed: OSStatus \(status)")
            return .aggregateCreationFailed(
                makeAggregateContext(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate
                )
            )
        case .aggregateVerification(let message):
            report("Aggregate verification failed: \(message)")
            return .aggregateCreationFailed(
                makeAggregateContext(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate
                )
            )
        case .auHALCreation(let status):
            report("AUHAL creation failed: OSStatus \(status)")
            return .auHALCreationFailed(
                makeAUHALContext(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate
                )
            )
        case .auHAL(let failure):
            report("AUHAL setup failed at \(failure.stage.rawValue): OSStatus \(failure.status)")
            return .auHALConfigurationFailed(
                stage: failure.stage,
                context: makeAUHALContext(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate
                )
            )
        case .cleanup(let failures):
            failures.forEach { report($0) }
            return .cleanupFailed(failures)
        }
    }

    private func makeAggregateContext(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double
    ) -> AggregateDeviceContext {
        AggregateDeviceContext(
            inputUID: input.id,
            outputUID: output.id,
            nominalSampleRate: nominalSampleRate
        )
    }

    private func makeAUHALContext(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double
    ) -> AUHALContext {
        AUHALContext(
            inputUID: input.id,
            outputUID: output.id,
            nominalSampleRate: nominalSampleRate
        )
    }

    private func report(_ message: String) {
        coreAudioServiceLogger.error("\(message, privacy: .public)")
        logStore?.append(source: .routing, message: message)
    }

    private func inform(_ message: String) {
        coreAudioServiceLogger.info("\(message, privacy: .public)")
        logStore?.append(source: .routing, message: message)
    }
}
