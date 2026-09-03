@testable import ScreamBar
import AudioToolbox
import XCTest

final class AsyncSRCPlaythroughTeardownTests: XCTestCase {
    private static let injectedFailure: OSStatus = -7_101

    func testStartUsesOutputFirstThenInput() throws {
        let operations = AsyncSRCAudioUnitOperationsSpy()
        let playthrough = makePlaythrough(
            started: false,
            callbacksInstalled: false,
            hasRenderContext: false,
            operations: operations
        )

        try playthrough.start()

        XCTAssertEqual(
            operations.events,
            ["start output AUHAL", "start input AUHAL"]
        )
    }

    func testInputStartFailureRollsBackStartedOutput() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.start, .inputAUHAL): [Self.injectedFailure],
            ]
        )
        let playthrough = makePlaythrough(
            started: false,
            callbacksInstalled: false,
            hasRenderContext: false,
            operations: operations
        )

        XCTAssertThrowsError(try playthrough.start()) { error in
            guard let failure = error as? AUHALSetupFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.stage, .inputIO)
            XCTAssertEqual(failure.status, Self.injectedFailure)
        }
        XCTAssertEqual(
            operations.events,
            [
                "start output AUHAL",
                "start input AUHAL",
                "stop output AUHAL",
            ]
        )
    }

    func testOutputStartFailureDoesNotOpenInput() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.start, .outputAUHAL): [Self.injectedFailure],
            ]
        )
        let playthrough = makePlaythrough(
            started: false,
            callbacksInstalled: false,
            hasRenderContext: false,
            operations: operations
        )

        XCTAssertThrowsError(try playthrough.start())
        XCTAssertEqual(operations.events, ["start output AUHAL"])
    }

    func testFailedStartRollbackLeavesOutputForTeardownRetry() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.start, .inputAUHAL): [Self.injectedFailure],
                .init(.stop, .outputAUHAL): [Self.injectedFailure, noErr],
            ]
        )
        let playthrough = makePlaythrough(
            started: false,
            callbacksInstalled: true,
            hasRenderContext: true,
            operations: operations
        )

        XCTAssertThrowsError(try playthrough.start())
        XCTAssertFalse(playthrough.isFullyDisposed)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.count("stop output AUHAL"), 2)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testOutputStopFailureDoesNotPreventInputClosure() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.stop, .outputAUHAL): [Self.injectedFailure, noErr],
            ]
        )
        let playthrough = makePlaythrough(operations: operations)

        let failures = playthrough.stopAndDispose()

        XCTAssertEqual(
            failures,
            [
                "Direct SRC: stopping output AUHAL failed: OSStatus -7101 (non-printable)",
            ]
        )
        XCTAssertTrue(operations.events.contains("stop input AUHAL"))
        XCTAssertTrue(operations.events.contains("uninitialize input AUHAL"))
        XCTAssertTrue(operations.events.contains("dispose input AUHAL"))
        XCTAssertFalse(operations.events.contains("dispose output AUHAL"))
        XCTAssertFalse(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.destroyContextCount, 0)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.count("stop input AUHAL"), 1)
        XCTAssertEqual(operations.count("dispose input AUHAL"), 1)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testUninitializeFailuresDoNotPreventIndependentDisposal() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.uninitialize, .inputAUHAL): [Self.injectedFailure],
                .init(.uninitialize, .outputAUHAL): [Self.injectedFailure],
                .init(.uninitialize, .varispeed): [Self.injectedFailure],
            ]
        )
        let playthrough = makePlaythrough(operations: operations)

        let failures = playthrough.stopAndDispose()

        XCTAssertEqual(failures.count, 3)
        XCTAssertTrue(failures[0].contains("uninitializing input AUHAL"))
        XCTAssertTrue(failures[1].contains("uninitializing output AUHAL"))
        XCTAssertTrue(failures[2].contains("uninitializing Varispeed"))
        XCTAssertTrue(operations.events.contains("dispose input AUHAL"))
        XCTAssertTrue(operations.events.contains("dispose output AUHAL"))
        XCTAssertTrue(operations.events.contains("dispose Varispeed"))
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testFailedCallbackRemovalAndDisposalRetainContextForRetry() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.clearCallback, .inputAUHAL): [Self.injectedFailure, noErr],
                .init(.dispose, .inputAUHAL): [Self.injectedFailure, noErr],
            ]
        )
        let playthrough = makePlaythrough(operations: operations)

        let failures = playthrough.stopAndDispose()

        XCTAssertTrue(failures.contains { $0.contains("removing input callback") })
        XCTAssertTrue(failures.contains { $0.contains("disposing input AUHAL") })
        XCTAssertEqual(operations.destroyContextCount, 0)
        XCTAssertFalse(playthrough.isFullyDisposed)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testInputOnlyPartialConstructionRetainsContextUntilCallbackRetry() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.clearCallback, .inputAUHAL): [Self.injectedFailure, noErr],
                .init(.dispose, .inputAUHAL): [Self.injectedFailure, noErr],
            ]
        )
        let playthrough = makePlaythrough(
            started: false,
            initialized: false,
            callbacksInstalled: false,
            inputCallbackInstalled: true,
            operations: operations
        )

        let failures = playthrough.stopAndDispose()

        XCTAssertTrue(failures.contains { $0.contains("removing input callback") })
        XCTAssertTrue(failures.contains { $0.contains("disposing input AUHAL") })
        XCTAssertEqual(operations.count("clear callback input"), 1)
        XCTAssertEqual(operations.count("clear callback output"), 0)
        XCTAssertEqual(operations.count("clear callback Varispeed source"), 0)
        XCTAssertEqual(operations.destroyContextCount, 0)
        XCTAssertFalse(playthrough.isFullyDisposed)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(
            Array(operations.events.suffix(3)),
            [
                "clear callback input",
                "dispose input AUHAL",
                "destroy context",
            ]
        )
        XCTAssertEqual(operations.destroyContextCount, 1)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testInputAndSourcePartialConstructionRetainsContextUntilCallbackRetry() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.clearCallback, .varispeed): [Self.injectedFailure, noErr],
                .init(.dispose, .varispeed): [Self.injectedFailure, noErr],
            ]
        )
        let playthrough = makePlaythrough(
            started: false,
            initialized: false,
            callbacksInstalled: false,
            inputCallbackInstalled: true,
            sourceCallbackInstalled: true,
            operations: operations
        )

        let failures = playthrough.stopAndDispose()

        XCTAssertTrue(
            failures.contains { $0.contains("removing Varispeed source callback") }
        )
        XCTAssertTrue(failures.contains { $0.contains("disposing Varispeed") })
        XCTAssertEqual(operations.count("clear callback input"), 1)
        XCTAssertEqual(operations.count("clear callback output"), 0)
        XCTAssertEqual(operations.count("clear callback Varispeed source"), 1)
        XCTAssertEqual(operations.destroyContextCount, 0)
        XCTAssertFalse(playthrough.isFullyDisposed)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(
            Array(operations.events.suffix(3)),
            [
                "clear callback Varispeed source",
                "dispose Varispeed",
                "destroy context",
            ]
        )
        XCTAssertEqual(operations.destroyContextCount, 1)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testEveryDisposeIsAttemptedWhenIndependentDisposalsFail() {
        let operations = AsyncSRCAudioUnitOperationsSpy(
            statuses: [
                .init(.dispose, .inputAUHAL): [Self.injectedFailure],
                .init(.dispose, .outputAUHAL): [Self.injectedFailure],
                .init(.dispose, .varispeed): [Self.injectedFailure],
            ]
        )
        let playthrough = makePlaythrough(operations: operations)

        let failures = playthrough.stopAndDispose()

        XCTAssertEqual(failures.count, 3)
        XCTAssertEqual(operations.count("dispose input AUHAL"), 1)
        XCTAssertEqual(operations.count("dispose output AUHAL"), 1)
        XCTAssertEqual(operations.count("dispose Varispeed"), 1)
        XCTAssertFalse(playthrough.isFullyDisposed)
        XCTAssertEqual(
            operations.destroyContextCount,
            1,
            "Cleared callbacks make the context safe to release even if disposal must retry"
        )
    }

    func testSuccessfulTeardownReleasesEveryResourceAndIsIdempotent() {
        let operations = AsyncSRCAudioUnitOperationsSpy()
        let playthrough = makePlaythrough(operations: operations)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.destroyContextCount, 1)

        let eventCount = operations.events.count
        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.events.count, eventCount)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testMeasuredPostInitializationLatencyCanDemoteLowLatencyRoute() {
        let provisionalConfiguration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 64,
            outputBufferFrames: 64,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )
        let measuredConfiguration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 64,
            outputBufferFrames: 64,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100,
            converterLatencySeconds: 0.020
        )

        let measured = AsyncSRCPlaythrough.measuredLatency(
            bufferConfiguration: measuredConfiguration,
            configuredInputQuantumFrames: 64,
            inputSampleRate: 48_000,
            converterLatencySeconds: 0.020
        )

        XCTAssertTrue(
            AsyncSRCPlaythrough.requiresContextRebuild(
                current: provisionalConfiguration,
                measured: measuredConfiguration
            )
        )
        XCTAssertNotEqual(
            provisionalConfiguration.targetFillFrames,
            measuredConfiguration.targetFillFrames
        )
        XCTAssertNotEqual(
            provisionalConfiguration.maximumTargetFillFrames,
            measuredConfiguration.maximumTargetFillFrames
        )
        XCTAssertNotEqual(
            provisionalConfiguration.ringCapacityFrames,
            measuredConfiguration.ringCapacityFrames
        )
        XCTAssertFalse(measured.isLowLatency)
        XCTAssertEqual(
            measured.estimatedSeconds,
            measuredConfiguration.estimatedApplicationLatencySeconds,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            measured.maximumSeconds,
            measuredConfiguration.maximumApplicationLatencySeconds,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            measured.maximumSeconds,
            AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
        XCTAssertLessThanOrEqual(measured.estimatedSeconds, measured.maximumSeconds)
    }

    private func makePlaythrough(
        started: Bool = true,
        initialized: Bool = true,
        callbacksInstalled: Bool = true,
        inputCallbackInstalled: Bool? = nil,
        outputCallbackInstalled: Bool? = nil,
        sourceCallbackInstalled: Bool? = nil,
        hasRenderContext: Bool = true,
        operations: AsyncSRCAudioUnitOperationsSpy
    ) -> AsyncSRCPlaythrough {
        AsyncSRCPlaythrough(
            testingInputAudioUnit: AudioUnit(bitPattern: 1),
            testingOutputAudioUnit: AudioUnit(bitPattern: 2),
            testingVarispeedAudioUnit: AudioUnit(bitPattern: 3),
            renderContext: hasRenderContext
                ? OpaquePointer(bitPattern: 4)
                : nil,
            inputInitialized: initialized,
            outputInitialized: initialized,
            varispeedInitialized: initialized,
            inputStarted: started,
            outputStarted: started,
            testingInputCallbackInstalled:
                inputCallbackInstalled ?? callbacksInstalled,
            testingOutputCallbackInstalled:
                outputCallbackInstalled ?? callbacksInstalled,
            testingSourceCallbackInstalled:
                sourceCallbackInstalled ?? callbacksInstalled,
            audioUnitOperations: operations.makeOperations()
        )
    }
}

private final class AsyncSRCAudioUnitOperationsSpy {
    enum Operation: Hashable {
        case start
        case stop
        case clearCallback
        case uninitialize
        case dispose
    }

    struct Key: Hashable {
        let operation: Operation
        let role: AsyncSRCAudioUnitRole

        init(_ operation: Operation, _ role: AsyncSRCAudioUnitRole) {
            self.operation = operation
            self.role = role
        }
    }

    private var statuses: [Key: [OSStatus]]
    private(set) var events: [String] = []
    private(set) var destroyContextCount = 0

    init(statuses: [Key: [OSStatus]] = [:]) {
        self.statuses = statuses
    }

    func makeOperations() -> AsyncSRCAudioUnitOperations {
        AsyncSRCAudioUnitOperations(
            start: { [weak self] _, role in
                self?.status(for: .start, role: role) ?? kAudio_ParamError
            },
            stop: { [weak self] _, role in
                self?.status(for: .stop, role: role) ?? kAudio_ParamError
            },
            clearCallback: { [weak self] _, callbackRole in
                guard let self else { return kAudio_ParamError }
                let audioUnitRole = self.audioUnitRole(for: callbackRole)
                return self.status(
                    for: .clearCallback,
                    role: audioUnitRole,
                    eventRole: callbackRole.rawValue
                )
            },
            uninitialize: { [weak self] _, role in
                self?.status(for: .uninitialize, role: role)
                    ?? kAudio_ParamError
            },
            dispose: { [weak self] _, role in
                self?.status(for: .dispose, role: role) ?? kAudio_ParamError
            },
            destroyRenderContext: { [weak self] _ in
                self?.destroyContextCount += 1
                self?.events.append("destroy context")
            }
        )
    }

    func count(_ event: String) -> Int {
        events.filter { $0 == event }.count
    }

    private func status(
        for operation: Operation,
        role: AsyncSRCAudioUnitRole,
        eventRole: String? = nil
    ) -> OSStatus {
        events.append("\(operationName(operation)) \(eventRole ?? role.rawValue)")
        let key = Key(operation, role)
        guard var queuedStatuses = statuses[key], !queuedStatuses.isEmpty else {
            return noErr
        }
        let status = queuedStatuses.removeFirst()
        statuses[key] = queuedStatuses
        return status
    }

    private func audioUnitRole(
        for callbackRole: AsyncSRCCallbackRole
    ) -> AsyncSRCAudioUnitRole {
        switch callbackRole {
        case .input:
            return .inputAUHAL
        case .output:
            return .outputAUHAL
        case .varispeedSource:
            return .varispeed
        }
    }

    private func operationName(_ operation: Operation) -> String {
        switch operation {
        case .start:
            return "start"
        case .stop:
            return "stop"
        case .clearCallback:
            return "clear callback"
        case .uninitialize:
            return "uninitialize"
        case .dispose:
            return "dispose"
        }
    }
}
