import CoreAudio
import Foundation
import os

private let legacyCoreAudioLogger = Logger(
    subsystem: "com.screambar.app",
    category: "LegacyCoreAudioBackend"
)

enum LegacyRouteFailure: Error {
    case bufferFrameSizeConfiguration(BufferFrameSizeConfigurationContext)
    case aggregateUnsupported(OSStatus)
    case aggregateCreation(OSStatus)
    case aggregateVerification(String)
    case auHALCreation(OSStatus)
    case auHAL(AUHALSetupFailure)
    case cleanup([String])
}

private struct RetainedAggregateConstructionFailure: Error {
    let primaryError: Error
    let aggregateDeviceID: AudioDeviceID
    let cleanupStatus: OSStatus
}

struct BufferFrameSizeRestore: Equatable {
    let deviceUID: AudioDeviceUID
    let frameCount: UInt32
    let appliedFrameCount: UInt32
}

struct BufferFrameSizeRestoreResult: Equatable {
    let retryableRestores: [BufferFrameSizeRestore]
    let failures: [String]
}

private struct BufferFrameSizeRestoreReadbackFailure: LocalizedError {
    let deviceUID: AudioDeviceUID
    let expectedFrameCount: UInt32
    let observedFrameCount: UInt32

    var errorDescription: String? {
        "Expected \(deviceUID.rawValue) to restore \(expectedFrameCount) frames, observed \(observedFrameCount)"
    }
}

struct CoreAudioListenerOperations {
    let add: (
        AudioObjectID,
        UnsafePointer<AudioObjectPropertyAddress>,
        DispatchQueue,
        @escaping (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    ) -> OSStatus
    let remove: (
        AudioObjectID,
        UnsafePointer<AudioObjectPropertyAddress>,
        DispatchQueue,
        @escaping (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    ) -> OSStatus
    /// Returns nil when device presence cannot be determined without risking a false decision.
    let isDevicePresent: (AudioObjectID) -> Bool?

    init(
        add: @escaping (
            AudioObjectID,
            UnsafePointer<AudioObjectPropertyAddress>,
            DispatchQueue,
            @escaping (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
        ) -> OSStatus,
        remove: @escaping (
            AudioObjectID,
            UnsafePointer<AudioObjectPropertyAddress>,
            DispatchQueue,
            @escaping (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
        ) -> OSStatus,
        isDevicePresent: @escaping (AudioObjectID) -> Bool? = { _ in nil }
    ) {
        self.add = add
        self.remove = remove
        self.isDevicePresent = isDevicePresent
    }

    static let live = CoreAudioListenerOperations(
        add: { objectID, address, queue, block in
            AudioObjectAddPropertyListenerBlock(objectID, address, queue, block)
        },
        remove: { objectID, address, queue, block in
            AudioObjectRemovePropertyListenerBlock(objectID, address, queue, block)
        },
        isDevicePresent: { objectID in
            let devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            do {
                return try CoreAudioPropertyReader.readDeviceIDs(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    address: devicesAddress
                ).contains(objectID)
            } catch {
                legacyCoreAudioLogger.debug(
                    "Could not confirm CoreAudio device presence while removing a listener: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    )
}

struct AggregateSubdeviceState: Equatable {
    let uid: AudioDeviceUID
    let driftCompensation: UInt32
}

@MainActor
final class LegacyCoreAudioBackend: CoreAudioBackend {
    var onHardwareChanged: (() -> Void)?
    var onAsyncSRCMetricsFinalized: ((UUID, AsyncSRCMetrics) -> Void)?

    private struct ListenerRegistration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    }

    private final class RouteResources {
        var aggregateDeviceID: AudioDeviceID?
        var playthrough: (any CoreAudioRouteTransport)?
        var bufferFrameSizeRestores: [BufferFrameSizeRestore]
        var stabilityCheckpoint = AsyncSRCStabilityCounters.zero
        var didPublishFinalAsyncSRCMetrics = false

        init(
            aggregateDeviceID: AudioDeviceID? = nil,
            playthrough: (any CoreAudioRouteTransport)? = nil,
            bufferFrameSizeRestores: [BufferFrameSizeRestore] = []
        ) {
            self.aggregateDeviceID = aggregateDeviceID
            self.playthrough = playthrough
            self.bufferFrameSizeRestores = bufferFrameSizeRestores
        }

        var hasLiveCoreAudioResources: Bool {
            playthrough != nil
                || aggregateDeviceID != nil
                || !bufferFrameSizeRestores.isEmpty
        }
    }

    private static let aggregateName = "ScreamBar Direct Routing"
    private static let aggregateUIDPrefix = "com.screambar.direct-routing."
    private static let defaultDeviceResolutionAttempts = 3
    private static let listenerCleanupRetryMessage =
        "CoreAudio device monitoring cleanup is pending and will be retried"
    private static let listenerCleanupRetryLimit = 3
    private static let listenerCleanupRetryBaseNanoseconds: UInt64 = 250_000_000

    private let listenerQueue = DispatchQueue(
        label: "com.screambar.coreaudio-listeners",
        qos: .userInitiated
    )
    private let listenerOperations: CoreAudioListenerOperations
    private let allDeviceIDsProvider: () throws -> [AudioDeviceID]
    private let listenerCleanupRetrySleep: (UInt64) async throws -> Void
    private var listeners: [ListenerRegistration] = []
    private var listenerCleanupRetryTask: Task<Void, Never>?
    private var routes: [UUID: RouteResources] = [:]
    private var pendingCleanupRoutes: [UUID: RouteResources] = [:]

    init(
        listenerOperations: CoreAudioListenerOperations = .live,
        allDeviceIDsProvider: @escaping () throws -> [AudioDeviceID] = {
            try CoreAudioPropertyReader.readDeviceIDs(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        },
        listenerCleanupRetrySleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.listenerOperations = listenerOperations
        self.allDeviceIDsProvider = allDeviceIDsProvider
        self.listenerCleanupRetrySleep = listenerCleanupRetrySleep
    }

    func startMonitoring() throws {
        try rebuildListeners()
    }

    @discardableResult
    func stopMonitoring() -> [String] {
        var retainedRegistrations: [ListenerRegistration] = []
        var failures: [String] = []
        for registration in listeners {
            if isDisconnectedDeviceListener(registration) {
                logDiscardedDisconnectedListener(registration)
                continue
            }
            var address = registration.address
            let status = listenerOperations.remove(
                registration.objectID,
                &address,
                listenerQueue,
                registration.block
            )
            if status != noErr {
                if isDisconnectedDeviceListener(registration) {
                    logDiscardedDisconnectedListener(registration)
                    continue
                }
                retainedRegistrations.append(registration)
                failures.append(Self.listenerCleanupRetryMessage)
                legacyCoreAudioLogger.debug(
                    "CoreAudio listener removal will be retried for \(CoreAudioPropertyReader.selectorDescription(registration.address.mSelector), privacy: .public); object=\(registration.objectID), status=\(CoreAudioBackendFailure.statusDescription(for: status), privacy: .public)"
                )
            }
        }
        listeners = retainedRegistrations
        return failures
    }

    func rebuildListeners() throws {
        listenerCleanupRetryTask?.cancel()
        listenerCleanupRetryTask = nil
        do {
            if try reconcileListeners() {
                scheduleListenerCleanupRetry(attempt: 1)
            }
        } catch {
            legacyCoreAudioLogger.debug(
                "CoreAudio listener reconciliation was incomplete and will be retried: \(error.localizedDescription, privacy: .public)"
            )
            scheduleListenerCleanupRetry(attempt: 1)
            throw error
        }
    }

    private func reconcileListeners() throws -> Bool {
        let removalFailures = stopMonitoring()
        if !removalFailures.isEmpty {
            legacyCoreAudioLogger.debug(
                "CoreAudio listener reconciliation retained \(removalFailures.count) live registration(s) for a later debounced retry."
            )
        }

        for address in Self.monitoredSystemPropertyAddresses {
            try addListenerIfNeeded(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: address
            )
        }

        for deviceID in try allDeviceIDs() {
            do {
                if try isOwnedAggregate(deviceID: deviceID) {
                    continue
                }
            } catch {
                legacyCoreAudioLogger.warning(
                    "Skipping listeners for unreadable CoreAudio device \(deviceID): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            let deviceAddresses = Self.monitoredDevicePropertyAddresses
            for address in deviceAddresses {
                if CoreAudioPropertyReader.hasProperty(
                    objectID: deviceID,
                    address: address
                ) {
                    do {
                        try addListenerIfNeeded(objectID: deviceID, address: address)
                    } catch {
                        if listenerOperations.isDevicePresent(deviceID) == false {
                            legacyCoreAudioLogger.debug(
                                "Skipped \(CoreAudioPropertyReader.selectorDescription(address.mSelector), privacy: .public) listener because the CoreAudio device disappeared during reconciliation."
                            )
                            continue
                        }
                        throw error
                    }
                }
            }
        }
        return !removalFailures.isEmpty
    }

    static var monitoredSystemPropertyAddresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
    }

    static var monitoredDevicePropertyAddresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
    }

    func makeSnapshot(revision: UInt64) throws -> AudioHardwareSnapshot {
        let devices = try allDeviceIDs().compactMap { deviceID -> AudioDeviceDescriptor? in
            do {
                if try isOwnedAggregate(deviceID: deviceID) {
                    return nil
                }
                return try descriptor(for: deviceID)
            } catch {
                legacyCoreAudioLogger.warning(
                    "Ignoring unreadable CoreAudio device \(deviceID): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        return AudioHardwareSnapshot(
            revision: revision,
            devices: Self.sortedDevices(devices),
            defaultInputUID: try defaultDeviceUID(
                selector: kAudioHardwarePropertyDefaultInputDevice
            ),
            defaultOutputUID: try defaultDeviceUID(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
        )
    }

    func currentNominalSampleRate(for uid: AudioDeviceUID) throws -> Double {
        let deviceID = try deviceID(for: uid)
        return try CoreAudioPropertyReader.readFloat64(
            objectID: deviceID,
            address: nominalSampleRateAddress
        )
    }

    func setNominalSampleRate(_ rate: Double, for uid: AudioDeviceUID) throws {
        let deviceID = try deviceID(for: uid)
        try CoreAudioPropertyReader.writeFloat64(
            rate,
            objectID: deviceID,
            address: nominalSampleRateAddress
        )
    }

    func isAlive(uid: AudioDeviceUID) throws -> Bool {
        let deviceID = try deviceID(for: uid)
        return try CoreAudioPropertyReader.readUInt32(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ) != 0
    }

    func prepareRoute(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        sampleRatePlan: AudioSampleRatePlan,
        requestedBufferFrameSize: UInt32?,
        validateOwnership: () throws -> Void
    ) throws -> UUID {
        try validateOwnership()
        let pendingFailures = retryPendingCleanups()
        guard pendingCleanupRoutes.isEmpty else {
            throw LegacyRouteFailure.cleanup(pendingFailures)
        }

        let inputDeviceID = try deviceID(for: input.id)
        let outputDeviceID = try deviceID(for: output.id)
        let resources = RouteResources()

        do {
            if let requestedBufferFrameSize {
                try validateOwnership()
                if let outputRestore = try configureBufferFrameSize(
                    requestedBufferFrameSize,
                    deviceUID: output.id,
                    deviceID: outputDeviceID
                ) {
                    resources.bufferFrameSizeRestores.append(outputRestore)
                }
                if input.id != output.id {
                    try validateOwnership()
                    if let inputRestore = try configureBufferFrameSize(
                        requestedBufferFrameSize,
                        deviceUID: input.id,
                        deviceID: inputDeviceID
                    ) {
                        resources.bufferFrameSizeRestores.append(inputRestore)
                    }
                }
            }

            switch sampleRatePlan {
            case let .synchronized(nominalSampleRate):
                try prepareSynchronizedPlaythrough(
                    input: input,
                    output: output,
                    inputDeviceID: inputDeviceID,
                    outputDeviceID: outputDeviceID,
                    nominalSampleRate: nominalSampleRate,
                    requestedBufferFrameSize: requestedBufferFrameSize,
                    resources: resources,
                    validateOwnership: validateOwnership
                )
            case let .converted(inputSampleRate, outputSampleRate):
                try validateOwnership()
                do {
                    resources.playthrough = try AsyncSRCPlaythrough.make(
                        inputDeviceID: inputDeviceID,
                        outputDeviceID: outputDeviceID,
                        inputChannelCount: input.inputChannelCount,
                        outputChannelCount: output.outputChannelCount,
                        inputSampleRate: inputSampleRate,
                        outputSampleRate: outputSampleRate,
                        inputBufferFrames: requestedBufferFrameSize
                            ?? input.currentBufferFrameSize,
                        outputBufferFrames: requestedBufferFrameSize
                            ?? output.currentBufferFrameSize
                    )
                } catch let failure as AsyncSRCPlaythroughRetainedConstructionFailure {
                    resources.playthrough = failure.playthrough
                    failure.cleanupFailures.forEach {
                        legacyCoreAudioLogger.error("\($0, privacy: .public)")
                    }
                    throw translatedConstructionError(failure.primaryError)
                } catch let failure as AUHALCreationFailure {
                    throw LegacyRouteFailure.auHALCreation(failure.status)
                } catch let failure as AUHALSetupFailure {
                    throw LegacyRouteFailure.auHAL(failure)
                }
            }

            let sessionID = UUID()
            routes[sessionID] = resources
            return sessionID
        } catch {
            let cleanupFailures = cleanup(resources: resources)
            if resources.hasLiveCoreAudioResources {
                pendingCleanupRoutes[UUID()] = resources
            }
            cleanupFailures.forEach {
                legacyCoreAudioLogger.error("\($0, privacy: .public)")
            }
            throw error
        }
    }

    func startRoute(sessionID: UUID) throws {
        guard let playthrough = routes[sessionID]?.playthrough else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        try playthrough.start()
    }

    func stopAndDestroyRoute(sessionID: UUID) -> [String] {
        guard let resources = routes[sessionID] else { return [] }
        let failures = cleanup(resources: resources, sessionID: sessionID)
        if !resources.hasLiveCoreAudioResources {
            routes.removeValue(forKey: sessionID)
        }
        return failures
    }

    func verifyRouteResourcesReleased() -> [String] {
        var failures = retryPendingCleanups()
        if !routes.isEmpty {
            failures.append("Direct: active route resources remain registered")
        }
        if !pendingCleanupRoutes.isEmpty {
            failures.append("Direct: pending route resources remain registered")
        }
        return failures
    }

    func asyncSRCMetrics(sessionID: UUID) -> AsyncSRCMetrics? {
        (routes[sessionID]?.playthrough as? AsyncSRCPlaythrough)?.metrics
    }

    func asyncSRCConverterLatency(sessionID: UUID) -> Double? {
        (routes[sessionID]?.playthrough as? AsyncSRCPlaythrough)?
            .converterLatencySeconds
    }

    func routeLatency(sessionID: UUID) -> CoreAudioRouteLatency? {
        guard let resources = routes[sessionID],
              let playthrough = resources.playthrough else { return nil }
        guard let convertedPlaythrough = playthrough as? AsyncSRCPlaythrough else {
            return CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0,
                maximumApplicationSeconds: 0,
                isLowLatency: true,
                requiresBufferEscalation: false
            )
        }
        let metrics = convertedPlaythrough.metrics
        let stabilityCounters = metrics.map {
            AsyncSRCStabilityCounters(metrics: $0)
                .subtracting(resources.stabilityCheckpoint)
        } ?? .zero
        let escalationReasons = metrics.map {
            Self.bufferEscalationReasons(
                metrics: $0,
                since: resources.stabilityCheckpoint
            )
        } ?? []
        return CoreAudioRouteLatency(
            estimatedApplicationSeconds:
                convertedPlaythrough.currentApplicationLatencySeconds,
            maximumApplicationSeconds:
                convertedPlaythrough.maximumApplicationLatencySeconds,
            isLowLatency: convertedPlaythrough.isLowLatency,
            requiresBufferEscalation: !escalationReasons.isEmpty,
            bufferEscalationReason: escalationReasons.isEmpty
                ? nil
                : escalationReasons.joined(separator: ", "),
            bufferEscalationIncidentCount:
                stabilityCounters.totalIncidentCount
        )
    }

    func checkpointRouteStability(sessionID: UUID) {
        guard let resources = routes[sessionID],
              let convertedPlaythrough = resources.playthrough
                as? AsyncSRCPlaythrough,
              let metrics = convertedPlaythrough.metrics else {
            return
        }
        resources.stabilityCheckpoint = AsyncSRCStabilityCounters(
            metrics: metrics
        )
    }

    nonisolated static func bufferEscalationReasons(
        metrics: AsyncSRCMetrics,
        since checkpoint: AsyncSRCStabilityCounters
    ) -> [String] {
        let counters = AsyncSRCStabilityCounters(metrics: metrics)
            .subtracting(checkpoint)
        return bufferEscalationReasons(
            counters: counters,
            callbackExceededConfiguredQuantum: false,
            missedCallbackDeadline: counters.hasMissedCallbackDeadline
        )
    }

    nonisolated static func requiresBufferEscalation(
        metrics: AsyncSRCMetrics,
        callbackExceededConfiguredQuantum: Bool,
        missedCallbackDeadline: Bool
    ) -> Bool {
        !bufferEscalationReasons(
            metrics: metrics,
            callbackExceededConfiguredQuantum: callbackExceededConfiguredQuantum,
            missedCallbackDeadline: missedCallbackDeadline
        ).isEmpty
    }

    nonisolated static func bufferEscalationReasons(
        metrics: AsyncSRCMetrics,
        callbackExceededConfiguredQuantum: Bool,
        missedCallbackDeadline: Bool
    ) -> [String] {
        bufferEscalationReasons(
            counters: AsyncSRCStabilityCounters(metrics: metrics),
            callbackExceededConfiguredQuantum:
                callbackExceededConfiguredQuantum,
            missedCallbackDeadline: missedCallbackDeadline
        )
    }

    private nonisolated static func bufferEscalationReasons(
        counters: AsyncSRCStabilityCounters,
        callbackExceededConfiguredQuantum: Bool,
        missedCallbackDeadline: Bool
    ) -> [String] {
        var reasons: [String] = []
        if counters.inputRenderErrorCount > 0 {
            reasons.append("input render errors: \(counters.inputRenderErrorCount)")
        }
        if counters.outputRenderErrorCount > 0 {
            reasons.append("output render errors: \(counters.outputRenderErrorCount)")
        }
        if counters.rateParameterErrorCount > 0 {
            reasons.append("converter rate errors: \(counters.rateParameterErrorCount)")
        }
        if counters.latencyCeilingOverflowCount > 0 {
            reasons.append(
                "FIFO writes above latency ceiling: \(counters.latencyCeilingOverflowCount)"
            )
        }
        if counters.inputCallbackFrameLimitExceededCount > 0 {
            reasons.append(
                "input callback frame-limit violations: \(counters.inputCallbackFrameLimitExceededCount)"
            )
        }
        if counters.outputCallbackFrameLimitExceededCount > 0 {
            reasons.append(
                "output callback frame-limit violations: \(counters.outputCallbackFrameLimitExceededCount)"
            )
        }
        if counters.overflowCount > 0 {
            reasons.append("FIFO overflows: \(counters.overflowCount)")
        }
        if counters.resynchronizationCount > 0 {
            reasons.append("FIFO resynchronizations: \(counters.resynchronizationCount)")
        }
        if counters.droppedInputFrames > 0 {
            reasons.append("dropped input frames: \(counters.droppedInputFrames)")
        }
        if counters.latencyCeilingUnderrunCount > 0 {
            reasons.append(
                "FIFO underruns at latency ceiling: \(counters.latencyCeilingUnderrunCount)"
            )
        } else if counters.underrunCount > 0 {
            reasons.append("FIFO underruns: \(counters.underrunCount)")
        }
        if callbackExceededConfiguredQuantum {
            reasons.append("callback exceeded the configured frame quantum")
        }
        if missedCallbackDeadline {
            reasons.append("callback execution exceeded its real-time deadline")
        }
        return reasons
    }

    func shutdown() -> [String] {
        listenerCleanupRetryTask?.cancel()
        listenerCleanupRetryTask = nil
        var failures: [String] = []
        for sessionID in Array(routes.keys) {
            failures.append(contentsOf: stopAndDestroyRoute(sessionID: sessionID))
        }
        failures.append(contentsOf: retryPendingCleanups())
        failures.append(contentsOf: stopMonitoring())
        return failures
    }

    private func cleanup(
        resources: RouteResources,
        sessionID: UUID? = nil
    ) -> [String] {
        var failures: [String] = []

        if let playthrough = resources.playthrough {
            failures.append(contentsOf: playthrough.stopAndDispose())
            guard playthrough.isFullyDisposed else { return failures }
            if let sessionID,
               !resources.didPublishFinalAsyncSRCMetrics,
               let convertedPlaythrough = playthrough as? AsyncSRCPlaythrough,
               let finalMetrics = convertedPlaythrough.metrics,
               let onAsyncSRCMetricsFinalized {
                onAsyncSRCMetricsFinalized(sessionID, finalMetrics)
                resources.didPublishFinalAsyncSRCMetrics = true
            }
            resources.playthrough = nil
        }

        if let aggregateDeviceID = resources.aggregateDeviceID {
            legacyCoreAudioLogger.debug(
                "Direct: destroying aggregate device \(aggregateDeviceID)"
            )
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            guard status == noErr else {
                let message = "Direct: aggregate destruction failed: \(CoreAudioBackendFailure.statusDescription(for: status))"
                legacyCoreAudioLogger.error("\(message, privacy: .public)")
                failures.append(message)
                return failures
            }
            resources.aggregateDeviceID = nil
            legacyCoreAudioLogger.debug("Direct: aggregate destroyed")
        }

        let restoreResult = restoreBufferFrameSizes(
            resources.bufferFrameSizeRestores
        )
        failures.append(contentsOf: restoreResult.failures)
        resources.bufferFrameSizeRestores = restoreResult.retryableRestores
        return failures
    }

    private func retryPendingCleanups() -> [String] {
        var failures: [String] = []
        for cleanupID in Array(pendingCleanupRoutes.keys) {
            guard let resources = pendingCleanupRoutes[cleanupID] else { continue }
            failures.append(contentsOf: cleanup(resources: resources))
            if !resources.hasLiveCoreAudioResources {
                pendingCleanupRoutes.removeValue(forKey: cleanupID)
            }
        }
        return failures
    }

    private func translatedConstructionError(_ error: Error) -> Error {
        if let failure = error as? AUHALCreationFailure {
            return LegacyRouteFailure.auHALCreation(failure.status)
        }
        if let failure = error as? AUHALSetupFailure {
            return LegacyRouteFailure.auHAL(failure)
        }
        return error
    }

    private func prepareSynchronizedPlaythrough(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?,
        resources: RouteResources,
        validateOwnership: () throws -> Void
    ) throws {
        let routeDeviceID: AudioDeviceID
        let inputChannelOffset: Int
        if input.id == output.id {
            routeDeviceID = inputDeviceID
            inputChannelOffset = 0
        } else {
            try validateOwnership()
            let createdAggregateID: AudioDeviceID
            do {
                createdAggregateID = try createAggregateDevice(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate,
                    requestedBufferFrameSize: requestedBufferFrameSize
                )
            } catch let failure as RetainedAggregateConstructionFailure {
                resources.aggregateDeviceID = failure.aggregateDeviceID
                legacyCoreAudioLogger.error(
                    "Initial aggregate cleanup failed: \(failure.cleanupStatus)"
                )
                throw failure.primaryError
            }
            resources.aggregateDeviceID = createdAggregateID
            routeDeviceID = createdAggregateID
            inputChannelOffset = output.inputChannelCount
        }

        do {
            try validateOwnership()
            resources.playthrough = try AUHALPlaythrough.make(
                deviceID: routeDeviceID,
                inputChannelCount: input.inputChannelCount,
                inputChannelOffset: inputChannelOffset,
                outputChannelCount: output.outputChannelCount,
                nominalSampleRate: nominalSampleRate
            )
        } catch let failure as AUHALRetainedConstructionFailure {
            resources.playthrough = failure.playthrough
            failure.cleanupFailures.forEach {
                legacyCoreAudioLogger.error("\($0, privacy: .public)")
            }
            throw translatedConstructionError(failure.primaryError)
        } catch let failure as AUHALCreationFailure {
            throw LegacyRouteFailure.auHALCreation(failure.status)
        } catch let failure as AUHALSetupFailure {
            throw LegacyRouteFailure.auHAL(failure)
        }
    }

    private var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var bufferFrameSizeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var bufferFrameSizeRangeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func isDisconnectedDeviceListener(_ registration: ListenerRegistration) -> Bool {
        guard registration.objectID != AudioObjectID(kAudioObjectSystemObject) else {
            return false
        }
        return listenerOperations.isDevicePresent(registration.objectID) == false
    }

    private func logDiscardedDisconnectedListener(_ registration: ListenerRegistration) {
        legacyCoreAudioLogger.debug(
            "Discarded \(CoreAudioPropertyReader.selectorDescription(registration.address.mSelector), privacy: .public) listener for a disconnected CoreAudio device."
        )
    }

    private func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws {
        let block: (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.onHardwareChanged?()
            }
        }
        var mutableAddress = address
        let status = listenerOperations.add(
            objectID,
            &mutableAddress,
            listenerQueue,
            block
        )
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Add CoreAudio listener", status: status)
        }
        listeners.append(
            ListenerRegistration(objectID: objectID, address: address, block: block)
        )
    }

    private func addListenerIfNeeded(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws {
        guard !listeners.contains(where: {
            $0.objectID == objectID
                && $0.address.mSelector == address.mSelector
                && $0.address.mScope == address.mScope
                && $0.address.mElement == address.mElement
        }) else {
            return
        }
        try addListener(objectID: objectID, address: address)
    }

    private func scheduleListenerCleanupRetry(attempt: Int) {
        guard attempt <= Self.listenerCleanupRetryLimit else { return }
        let delay = Self.listenerCleanupRetryBaseNanoseconds
            * UInt64(1 << (attempt - 1))
        let retrySleep = listenerCleanupRetrySleep
        listenerCleanupRetryTask = Task { @MainActor [weak self] in
            do {
                try await retrySleep(delay)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                legacyCoreAudioLogger.debug(
                    "CoreAudio listener retry delay failed: \(error.localizedDescription, privacy: .public)"
                )
                self.continueListenerCleanupRetry(after: attempt)
                return
            }
            guard let self, !Task.isCancelled else { return }
            do {
                let requiresAnotherRetry = try self.reconcileListeners()
                if requiresAnotherRetry {
                    self.continueListenerCleanupRetry(after: attempt)
                } else {
                    self.listenerCleanupRetryTask = nil
                }
            } catch {
                legacyCoreAudioLogger.debug(
                    "CoreAudio listener retry reconciliation failed: \(error.localizedDescription, privacy: .public)"
                )
                self.continueListenerCleanupRetry(after: attempt)
            }
        }
    }

    private func continueListenerCleanupRetry(after attempt: Int) {
        if attempt < Self.listenerCleanupRetryLimit {
            scheduleListenerCleanupRetry(attempt: attempt + 1)
        } else {
            listenerCleanupRetryTask = nil
            legacyCoreAudioLogger.debug(
                "CoreAudio listener cleanup remains pending after the bounded retry window."
            )
        }
    }

    var listenerRegistrationCountForTesting: Int {
        listeners.count
    }

    var listenerCleanupRetryScheduledForTesting: Bool {
        listenerCleanupRetryTask != nil
    }

    func installListenerRegistrationForTesting(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        let block: (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in }
        listeners.append(
            ListenerRegistration(objectID: objectID, address: address, block: block)
        )
    }

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        try allDeviceIDsProvider()
    }

    private func deviceID(for uid: AudioDeviceUID) throws -> AudioDeviceID {
        for deviceID in try allDeviceIDs() {
            do {
                let candidateUID = try CoreAudioPropertyReader.readString(
                    objectID: deviceID,
                    address: AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                )
                if candidateUID == uid.rawValue {
                    return deviceID
                }
            } catch {
                legacyCoreAudioLogger.warning(
                    "Ignoring unreadable CoreAudio device \(deviceID) while resolving UID: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        throw CoreAudioBackendFailure(
            operation: "Resolve device UID \(uid.rawValue)",
            status: kAudioHardwareBadDeviceError
        )
    }

    private func devicePresence(for uid: AudioDeviceUID) -> Bool? {
        let deviceIDs: [AudioDeviceID]
        do {
            deviceIDs = try allDeviceIDs()
        } catch {
            legacyCoreAudioLogger.debug(
                "Could not enumerate CoreAudio devices while classifying buffer restoration for \(uid.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        var encounteredUnreadableDevice = false
        for deviceID in deviceIDs {
            do {
                let candidateUID = try CoreAudioPropertyReader.readString(
                    objectID: deviceID,
                    address: AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                )
                if candidateUID == uid.rawValue {
                    return true
                }
            } catch {
                encounteredUnreadableDevice = true
                legacyCoreAudioLogger.debug(
                    "Could not read CoreAudio device \(deviceID) while classifying buffer restoration for \(uid.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return encounteredUnreadableDevice ? nil : false
    }

    private func isOwnedAggregate(deviceID: AudioDeviceID) throws -> Bool {
        let uid = try CoreAudioPropertyReader.readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        return uid.hasPrefix(Self.aggregateUIDPrefix)
    }

    private func descriptor(for deviceID: AudioDeviceID) throws -> AudioDeviceDescriptor {
        let uid = try CoreAudioPropertyReader.readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let name = try CoreAudioPropertyReader.readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let ranges = try CoreAudioPropertyReader.readValueRanges(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let bufferMetadata = readBufferFrameMetadata(deviceID: deviceID)
        let inputChannelCount = try CoreAudioPropertyReader.readChannelCount(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        let outputChannelCount = try CoreAudioPropertyReader.readChannelCount(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
        return AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: name,
            inputChannelCount: inputChannelCount,
            outputChannelCount: outputChannelCount,
            isAlive: try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ) != 0,
            currentNominalSampleRate: try CoreAudioPropertyReader.readFloat64(
                objectID: deviceID,
                address: nominalSampleRateAddress
            ),
            supportedNominalSampleRates: NominalSampleRateNegotiator.normalizedRanges(
                ranges.map {
                    NominalSampleRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum)
                }
            ),
            currentBufferFrameSize: bufferMetadata.current,
            supportedBufferFrameSizeRange: bufferMetadata.range,
            inputPhysicalStreamFormats: readPhysicalStreamFormats(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeInput
            ),
            outputPhysicalStreamFormats: readPhysicalStreamFormats(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            )
        )
    }

    private func readPhysicalStreamFormats(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioHardwareStreamFormat] {
        let streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        do {
            let streamIDs = try CoreAudioPropertyReader.readAudioObjectIDs(
                objectID: deviceID,
                address: streamsAddress
            )
            return streamIDs.compactMap { streamID in
                do {
                    let streamFormat = try CoreAudioPropertyReader.readStreamFormat(
                        objectID: streamID,
                        address: AudioObjectPropertyAddress(
                            mSelector: kAudioStreamPropertyPhysicalFormat,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain
                        )
                    )
                    return AudioHardwareStreamFormat(streamFormat)
                } catch {
                    legacyCoreAudioLogger.debug(
                        "Could not read physical stream format for CoreAudio stream \(streamID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return nil
                }
            }
        } catch {
            legacyCoreAudioLogger.debug(
                "Could not read physical stream formats for CoreAudio device \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private static func normalizedDeviceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    static func sortedDevices(
        _ devices: [AudioDeviceDescriptor]
    ) -> [AudioDeviceDescriptor] {
        devices.sorted {
            let leftName = normalizedDeviceName($0.name)
            let rightName = normalizedDeviceName($1.name)
            if leftName == rightName {
                return $0.id.rawValue < $1.id.rawValue
            }
            return leftName < rightName
        }
    }

    private func readBufferFrameMetadata(
        deviceID: AudioDeviceID
    ) -> (current: UInt32?, range: AudioBufferFrameSizeRange?) {
        let currentAddress = bufferFrameSizeAddress
        let rangeAddress = bufferFrameSizeRangeAddress
        guard CoreAudioPropertyReader.hasProperty(
            objectID: deviceID,
            address: currentAddress
        ), CoreAudioPropertyReader.hasProperty(
            objectID: deviceID,
            address: rangeAddress
        ) else {
            return (nil, nil)
        }

        do {
            let current = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: currentAddress
            )
            let valueRange = try CoreAudioPropertyReader.readValueRange(
                objectID: deviceID,
                address: rangeAddress
            )
            guard valueRange.mMinimum.isFinite,
                  valueRange.mMaximum.isFinite,
                  valueRange.mMinimum > 0,
                  valueRange.mMaximum >= valueRange.mMinimum,
                  valueRange.mMaximum <= Double(UInt32.max) else {
                legacyCoreAudioLogger.warning(
                    "Ignoring invalid buffer frame range for CoreAudio device \(deviceID)"
                )
                return (current, nil)
            }
            return (
                current,
                AudioBufferFrameSizeRange(
                    minimum: UInt32(valueRange.mMinimum.rounded(.up)),
                    maximum: UInt32(valueRange.mMaximum.rounded(.down))
                )
            )
        } catch {
            legacyCoreAudioLogger.warning(
                "Failed to read buffer frame metadata for CoreAudio device \(deviceID): \(error.localizedDescription, privacy: .public)"
            )
            return (nil, nil)
        }
    }

    private func defaultDeviceUID(
        selector: AudioObjectPropertySelector
    ) throws -> AudioDeviceUID? {
        var lastFailure: Error?
        for _ in 0..<Self.defaultDeviceResolutionAttempts {
            let deviceID = try CoreAudioPropertyReader.readAudioDeviceID(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
            guard deviceID != kAudioObjectUnknown else { return nil }
            do {
                let uid = try CoreAudioPropertyReader.readString(
                    objectID: deviceID,
                    address: AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                )
                return AudioDeviceUID(rawValue: uid)
            } catch let failure as CoreAudioBackendFailure
                where failure.status == kAudioHardwareBadObjectError {
                lastFailure = failure
            }
        }
        if let lastFailure {
            throw lastFailure
        }
        throw CoreAudioBackendFailure(
            operation: "Resolve default CoreAudio device",
            status: kAudioHardwareBadDeviceError
        )
    }

    private func createAggregateDevice(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?
    ) throws -> AudioDeviceID {
        let description = Self.makeAggregateDescription(input: input, output: output)

        var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let creationStatus = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateDeviceID
        )
        guard creationStatus == noErr else {
            if creationStatus == kAudioHardwareUnsupportedOperationError {
                throw LegacyRouteFailure.aggregateUnsupported(creationStatus)
            }
            throw LegacyRouteFailure.aggregateCreation(creationStatus)
        }

        do {
            try configureAndVerifyAggregate(
                aggregateDeviceID: aggregateDeviceID,
                expectedInputUID: input.id,
                expectedOutputUID: output.id,
                nominalSampleRate: nominalSampleRate,
                requestedBufferFrameSize: requestedBufferFrameSize
            )
            return aggregateDeviceID
        } catch {
            let cleanupStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if cleanupStatus != noErr {
                legacyCoreAudioLogger.error(
                    "Failed to destroy invalid aggregate: \(cleanupStatus)"
                )
                throw RetainedAggregateConstructionFailure(
                    primaryError: error,
                    aggregateDeviceID: aggregateDeviceID,
                    cleanupStatus: cleanupStatus
                )
            }
            throw error
        }
    }

    static func makeAggregateDescription(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) -> [String: Any] {
        let aggregateUID = "\(aggregateUIDPrefix)\(UUID().uuidString)"
        let outputSubdevice: [String: Any] = [
            kAudioSubDeviceUIDKey: output.id.rawValue,
            kAudioSubDeviceDriftCompensationKey: 0,
        ]
        let inputSubdevice: [String: Any] = [
            kAudioSubDeviceUIDKey: input.id.rawValue,
            kAudioSubDeviceDriftCompensationKey: 1,
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: output.id.rawValue,
            kAudioAggregateDeviceSubDeviceListKey: [outputSubdevice, inputSubdevice],
        ]
        return description
    }

    private func configureAndVerifyAggregate(
        aggregateDeviceID: AudioDeviceID,
        expectedInputUID: AudioDeviceUID,
        expectedOutputUID: AudioDeviceUID,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?
    ) throws {
        let activeSubdevices = try CoreAudioPropertyReader.readAudioObjectIDs(
            objectID: aggregateDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let activeSubdeviceUIDs = try activeSubdevices.map { subdeviceID in
            AudioDeviceUID(
                rawValue: try CoreAudioPropertyReader.readString(
                    objectID: subdeviceID,
                    address: AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                )
            )
        }
        try Self.validateAggregateMembership(
            activeSubdeviceUIDs,
            expectedInputUID: expectedInputUID,
            expectedOutputUID: expectedOutputUID
        )

        let composition = try CoreAudioPropertyReader.readDictionary(
            objectID: aggregateDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyComposition,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let subdeviceStates = try Self.aggregateSubdeviceStates(from: composition)
        try Self.validateAggregateSubdevices(
            subdeviceStates,
            expectedInputUID: expectedInputUID,
            expectedOutputUID: expectedOutputUID
        )

        try CoreAudioPropertyReader.writeFloat64(
            nominalSampleRate,
            objectID: aggregateDeviceID,
            address: nominalSampleRateAddress
        )
        let observedRate = try CoreAudioPropertyReader.readFloat64(
            objectID: aggregateDeviceID,
            address: nominalSampleRateAddress
        )
        guard NominalSampleRateNegotiator.ratesMatch(observedRate, nominalSampleRate) else {
            throw LegacyRouteFailure.aggregateVerification("Aggregate nominal sample rate mismatch")
        }

        let masterUID = try CoreAudioPropertyReader.readString(
            objectID: aggregateDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyMainSubDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        guard masterUID == expectedOutputUID.rawValue else {
            throw LegacyRouteFailure.aggregateVerification("Output is not the aggregate master")
        }

        if let requestedBufferFrameSize {
            try configureAggregateBufferFrameSize(
                requestedBufferFrameSize,
                aggregateDeviceID: aggregateDeviceID
            )
        }
    }

    static func validateAggregateSubdevices(
        _ states: [AggregateSubdeviceState],
        expectedInputUID: AudioDeviceUID,
        expectedOutputUID: AudioDeviceUID
    ) throws {
        try validateAggregateMembership(
            states.map(\.uid),
            expectedInputUID: expectedInputUID,
            expectedOutputUID: expectedOutputUID
        )
        guard states.first(where: { $0.uid == expectedOutputUID })?.driftCompensation == 0 else {
            throw LegacyRouteFailure.aggregateVerification(
                "Output subdevice drift compensation is enabled"
            )
        }
        guard states.first(where: { $0.uid == expectedInputUID })?.driftCompensation == 1 else {
            throw LegacyRouteFailure.aggregateVerification(
                "Input subdevice drift compensation is disabled"
            )
        }
    }

    static func aggregateSubdeviceStates(
        from composition: [String: Any]
    ) throws -> [AggregateSubdeviceState] {
        guard let rawSubdevices = composition[kAudioAggregateDeviceSubDeviceListKey]
                as? [Any] else {
            throw LegacyRouteFailure.aggregateVerification(
                "Aggregate composition has no subdevice list"
            )
        }
        return try rawSubdevices.map { rawSubdevice in
            guard let subdevice = rawSubdevice as? [String: Any],
                  let uid = subdevice[kAudioSubDeviceUIDKey] as? String,
                  let driftNumber = subdevice[kAudioSubDeviceDriftCompensationKey]
                    as? NSNumber else {
                throw LegacyRouteFailure.aggregateVerification(
                    "Aggregate composition has an invalid subdevice entry"
                )
            }
            return AggregateSubdeviceState(
                uid: AudioDeviceUID(rawValue: uid),
                driftCompensation: driftNumber.uint32Value
            )
        }
    }

    private static func validateAggregateMembership(
        _ observedUIDs: [AudioDeviceUID],
        expectedInputUID: AudioDeviceUID,
        expectedOutputUID: AudioDeviceUID
    ) throws {
        let expectedUIDs: Set<AudioDeviceUID> = [expectedInputUID, expectedOutputUID]
        guard observedUIDs.count == 2, Set(observedUIDs) == expectedUIDs else {
            throw LegacyRouteFailure.aggregateVerification(
                "Aggregate active subdevice membership is incorrect"
            )
        }
    }

    private func configureBufferFrameSize(
        _ requestedFrameCount: UInt32,
        deviceUID: AudioDeviceUID,
        deviceID: AudioDeviceID
    ) throws -> BufferFrameSizeRestore? {
        let originalFrameCount: UInt32
        do {
            originalFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
        } catch {
            throw LegacyRouteFailure.bufferFrameSizeConfiguration(
                BufferFrameSizeConfigurationContext(
                    deviceUID: deviceUID,
                    requestedFrameCount: requestedFrameCount,
                    observedFrameCount: nil,
                    operation: "read original buffer frame size"
                )
            )
        }
        guard originalFrameCount != requestedFrameCount else { return nil }

        do {
            try CoreAudioPropertyReader.writeUInt32(
                requestedFrameCount,
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            guard observedFrameCount == requestedFrameCount else {
                let restorationSuffix = immediateBufferRestoreSuffix(
                    originalFrameCount,
                    deviceUID: deviceUID,
                    deviceID: deviceID
                )
                throw LegacyRouteFailure.bufferFrameSizeConfiguration(
                    BufferFrameSizeConfigurationContext(
                        deviceUID: deviceUID,
                        requestedFrameCount: requestedFrameCount,
                        observedFrameCount: observedFrameCount,
                        operation: "verify buffer frame size\(restorationSuffix)"
                    )
                )
            }
        } catch let failure as LegacyRouteFailure {
            throw failure
        } catch {
            let restorationSuffix = immediateBufferRestoreSuffix(
                originalFrameCount,
                deviceUID: deviceUID,
                deviceID: deviceID
            )
            throw LegacyRouteFailure.bufferFrameSizeConfiguration(
                BufferFrameSizeConfigurationContext(
                    deviceUID: deviceUID,
                    requestedFrameCount: requestedFrameCount,
                    observedFrameCount: originalFrameCount,
                    operation: "set buffer frame size\(restorationSuffix)"
                )
            )
        }
        return BufferFrameSizeRestore(
            deviceUID: deviceUID,
            frameCount: originalFrameCount,
            appliedFrameCount: requestedFrameCount
        )
    }

    private func configureAggregateBufferFrameSize(
        _ requestedFrameCount: UInt32,
        aggregateDeviceID: AudioDeviceID
    ) throws {
        do {
            try CoreAudioPropertyReader.writeUInt32(
                requestedFrameCount,
                objectID: aggregateDeviceID,
                address: bufferFrameSizeAddress
            )
            let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: aggregateDeviceID,
                address: bufferFrameSizeAddress
            )
            guard observedFrameCount == requestedFrameCount else {
                throw LegacyRouteFailure.aggregateVerification(
                    "Aggregate buffer frame size mismatch: requested \(requestedFrameCount), observed \(observedFrameCount)"
                )
            }
        } catch let failure as LegacyRouteFailure {
            throw failure
        } catch {
            throw LegacyRouteFailure.aggregateVerification(
                "Failed to configure aggregate buffer frame size to \(requestedFrameCount): \(error.localizedDescription)"
            )
        }
    }

    private func restoreBufferFrameSizes(
        _ restores: [BufferFrameSizeRestore]
    ) -> BufferFrameSizeRestoreResult {
        Self.reconcileBufferFrameSizeRestores(
            restores,
            attemptRestore: { [self] restore in
                let restoredDeviceID = try deviceID(for: restore.deviceUID)
                let currentFrameCount = try CoreAudioPropertyReader.readUInt32(
                    objectID: restoredDeviceID,
                    address: bufferFrameSizeAddress
                )
                if currentFrameCount == restore.frameCount {
                    return
                }
                guard currentFrameCount == restore.appliedFrameCount else {
                    legacyCoreAudioLogger.warning(
                        "Not restoring buffer frame size for \(restore.deviceUID.rawValue, privacy: .public) because another client changed it to \(currentFrameCount)"
                    )
                    return
                }
                try CoreAudioPropertyReader.writeUInt32(
                    restore.frameCount,
                    objectID: restoredDeviceID,
                    address: bufferFrameSizeAddress
                )
                let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                    objectID: restoredDeviceID,
                    address: bufferFrameSizeAddress
                )
                guard observedFrameCount == restore.frameCount else {
                    throw BufferFrameSizeRestoreReadbackFailure(
                        deviceUID: restore.deviceUID,
                        expectedFrameCount: restore.frameCount,
                        observedFrameCount: observedFrameCount
                    )
                }
            },
            isDevicePresent: { [self] uid in
                devicePresence(for: uid)
            }
        )
    }

    static func reconcileBufferFrameSizeRestores(
        _ restores: [BufferFrameSizeRestore],
        attemptRestore: (BufferFrameSizeRestore) throws -> Void,
        isDevicePresent: (AudioDeviceUID) -> Bool?
    ) -> BufferFrameSizeRestoreResult {
        var retryableRestores: [BufferFrameSizeRestore] = []
        var failures: [String] = []
        for restore in restores.reversed() {
            do {
                try attemptRestore(restore)
            } catch {
                if isDevicePresent(restore.deviceUID) == false {
                    legacyCoreAudioLogger.debug(
                        "Discarding buffer frame size restoration for disconnected device \(restore.deviceUID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                retryableRestores.append(restore)
                failures.append(
                    "restore buffer frame size for \(restore.deviceUID.rawValue): \(error.localizedDescription)"
                )
            }
        }
        return BufferFrameSizeRestoreResult(
            retryableRestores: Array(retryableRestores.reversed()),
            failures: failures
        )
    }

    private func immediateBufferRestoreSuffix(
        _ originalFrameCount: UInt32,
        deviceUID: AudioDeviceUID,
        deviceID: AudioDeviceID
    ) -> String {
        do {
            try CoreAudioPropertyReader.writeUInt32(
                originalFrameCount,
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            guard observedFrameCount == originalFrameCount else {
                let message = "; restoring \(deviceUID.rawValue) to \(originalFrameCount) was not applied (observed \(observedFrameCount))"
                legacyCoreAudioLogger.error("\(message, privacy: .public)")
                return message
            }
            return ""
        } catch {
            let message = "; restoring \(deviceUID.rawValue) to \(originalFrameCount) also failed: \(error.localizedDescription)"
            legacyCoreAudioLogger.error("\(message, privacy: .public)")
            return message
        }
    }
}
