import Combine
import Foundation
import os

private let coreAudioServiceLogger = Logger(
    subsystem: "com.screambar.app",
    category: "CoreAudioDeviceService"
)

@MainActor
final class CoreAudioDeviceService: ObservableObject {
    private struct PreparationSignature {
        let inputUID: AudioDeviceUID
        let outputUID: AudioDeviceUID
        let nominalSampleRate: Double
        let inputRanges: [NominalSampleRateRange]
        let outputRanges: [NominalSampleRateRange]
        let requestedBufferFrameSize: UInt32?
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
    private weak var logStore: RollingLogStore?
    private var revision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var isPreparingRoute = false
    private var hasDeferredHardwareChange = false

    init(
        logStore: RollingLogStore,
        backend: (any CoreAudioBackend)? = nil
    ) {
        self.logStore = logStore
        self.backend = backend ?? CoreAudioBackendFactory.makeBackend()
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
        requestedBufferFrameSize: UInt32? = nil
    ) async throws -> PreparedAudioRoute {
        var expectedSignature: PreparationSignature?
        isPreparingRoute = true
        defer {
            isPreparingRoute = false
            let hadDeferredHardwareChange = hasDeferredHardwareChange
            hasDeferredHardwareChange = false
            do {
                try backend.rebuildListeners()
                let snapshotChanged = try refreshSnapshot(notifyRoute: false)
                if expectedSignature != nil {
                    if routeChanged(
                        inputSelection: inputSelection,
                        outputSelection: outputSelection,
                        expectedSignature: expectedSignature
                    ) {
                        onHardwareChanged?()
                    }
                } else if hadDeferredHardwareChange && snapshotChanged {
                    onHardwareChanged?()
                }
            } catch {
                report("Failed to refresh CoreAudio after route preparation: \(error.localizedDescription)")
            }
        }

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
        expectedSignature = PreparationSignature(
            inputUID: inputDevice.id,
            outputUID: outputDevice.id,
            nominalSampleRate: nominalSampleRate,
            inputRanges: inputDevice.supportedNominalSampleRates,
            outputRanges: outputDevice.supportedNominalSampleRates,
            requestedBufferFrameSize: requestedBufferFrameSize
        )

        try await configureAndVerifySampleRate(
            nominalSampleRate,
            for: outputDevice.id,
            operation: "output"
        )
        if inputDevice.id != outputDevice.id {
            try await configureAndVerifySampleRate(
                nominalSampleRate,
                for: inputDevice.id,
                operation: "input"
            )
        }

        guard try backend.isAlive(uid: inputDevice.id) else {
            throw AudioRoutingError.inputDeviceUnavailable(inputDevice.id)
        }
        guard try backend.isAlive(uid: outputDevice.id) else {
            throw AudioRoutingError.outputDeviceUnavailable(outputDevice.id)
        }

        let sessionID: UUID
        do {
            sessionID = try backend.prepareRoute(
                input: inputDevice,
                output: outputDevice,
                nominalSampleRate: nominalSampleRate,
                requestedBufferFrameSize: requestedBufferFrameSize
            )
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

    func startRoute(_ preparedRoute: PreparedAudioRoute) throws {
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
            cleanupFailures.forEach { report($0) }
            throw AudioRoutingError.cleanupFailed(cleanupFailures)
        }
    }

    func shutdown() {
        refreshTask?.cancel()
        refreshTask = nil
        let cleanupFailures = backend.shutdown()
        cleanupFailures.forEach { report($0) }
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
        operation: String
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
                try await Task.sleep(nanoseconds: Self.ratePollNanoseconds)
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
        if isPreparingRoute {
            hasDeferredHardwareChange = true
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.hardwareChangeDebounceNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                self?.report("Unexpected hardware debounce failure: \(error.localizedDescription)")
                return
            }
            guard let self else { return }
            guard !self.isPreparingRoute else {
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

    private func routeChanged(
        inputSelection: AudioDeviceSelection,
        outputSelection: AudioDeviceSelection,
        expectedSignature: PreparationSignature?
    ) -> Bool {
        guard let expectedSignature else { return true }
        do {
            let resolution = try resolveRoute(
                inputSelection: inputSelection,
                outputSelection: outputSelection
            )
            return resolution.input.id != expectedSignature.inputUID
                || resolution.output.id != expectedSignature.outputUID
                || !NominalSampleRateNegotiator.ratesMatch(
                    resolution.input.currentNominalSampleRate,
                    expectedSignature.nominalSampleRate
                )
                || !NominalSampleRateNegotiator.ratesMatch(
                    resolution.output.currentNominalSampleRate,
                    expectedSignature.nominalSampleRate
                )
                || resolution.input.supportedNominalSampleRates != expectedSignature.inputRanges
                || resolution.output.supportedNominalSampleRates != expectedSignature.outputRanges
                || bufferFrameSizeChanged(
                    resolution: resolution,
                    requestedFrameCount: expectedSignature.requestedBufferFrameSize
                )
        } catch {
            report("Route changed while preparing: \(error.localizedDescription)")
            return true
        }
    }

    private func bufferFrameSizeChanged(
        resolution: (
            input: AudioDeviceDescriptor,
            output: AudioDeviceDescriptor,
            isUsingOutputFallback: Bool
        ),
        requestedFrameCount: UInt32?
    ) -> Bool {
        guard let requestedFrameCount else { return false }
        return resolution.input.currentBufferFrameSize != requestedFrameCount
            || resolution.output.currentBufferFrameSize != requestedFrameCount
    }

    @discardableResult
    private func refreshSnapshot(notifyRoute: Bool) throws -> Bool {
        let previousSnapshot = snapshot
        revision &+= 1
        let refreshedSnapshot = try backend.makeSnapshot(revision: revision)
        let snapshotChanged = !hardwareStateMatches(previousSnapshot, refreshedSnapshot)
        snapshot = refreshedSnapshot
        if notifyRoute && snapshotChanged {
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
}
