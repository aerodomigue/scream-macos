@testable import ScreamBar
import CoreAudio
import XCTest

@MainActor
final class LegacyCoreAudioBackendContractTests: XCTestCase {
    func testAggregateValidationRequiresExactDriftConfiguration() throws {
        let inputUID = AudioDeviceUID(rawValue: "input")
        let outputUID = AudioDeviceUID(rawValue: "output")

        XCTAssertNoThrow(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(uid: outputUID, driftCompensation: 0),
                    AggregateSubdeviceState(uid: inputUID, driftCompensation: 1),
                ],
                expectedInputUID: inputUID,
                expectedOutputUID: outputUID
            )
        )

        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(uid: outputUID, driftCompensation: 1),
                    AggregateSubdeviceState(uid: inputUID, driftCompensation: 1),
                ],
                expectedInputUID: inputUID,
                expectedOutputUID: outputUID
            )
        )
        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(uid: outputUID, driftCompensation: 0),
                    AggregateSubdeviceState(uid: inputUID, driftCompensation: 0),
                ],
                expectedInputUID: inputUID,
                expectedOutputUID: outputUID
            )
        )
    }

    func testAggregateValidationRejectsUnexpectedMembership() {
        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(
                        uid: AudioDeviceUID(rawValue: "output"),
                        driftCompensation: 0
                    ),
                    AggregateSubdeviceState(
                        uid: AudioDeviceUID(rawValue: "unexpected"),
                        driftCompensation: 1
                    ),
                ],
                expectedInputUID: AudioDeviceUID(rawValue: "input"),
                expectedOutputUID: AudioDeviceUID(rawValue: "output")
            )
        )
    }

    func testAggregateCompositionReadbackParsesDriftState() throws {
        let states = try LegacyCoreAudioBackend.aggregateSubdeviceStates(
            from: [
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: "output",
                        kAudioSubDeviceDriftCompensationKey: NSNumber(value: 0),
                    ],
                    [
                        kAudioSubDeviceUIDKey: "input",
                        kAudioSubDeviceDriftCompensationKey: NSNumber(value: 1),
                    ],
                ],
            ]
        )

        XCTAssertEqual(
            states,
            [
                AggregateSubdeviceState(
                    uid: AudioDeviceUID(rawValue: "output"),
                    driftCompensation: 0
                ),
                AggregateSubdeviceState(
                    uid: AudioDeviceUID(rawValue: "input"),
                    driftCompensation: 1
                ),
            ]
        )
    }

    func testAggregateCompositionReadbackRejectsMissingDriftState() {
        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.aggregateSubdeviceStates(
                from: [
                    kAudioAggregateDeviceSubDeviceListKey: [
                        [kAudioSubDeviceUIDKey: "input"],
                    ],
                ]
            )
        )
    }

    func testFailedListenerRemovalIsRetainedAndRetried() {
        var removalStatuses: [OSStatus] = [-7_002, noErr]
        var removalCount = 0
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { _, _, _, _ in
                removalCount += 1
                return removalStatuses.removeFirst()
            },
            isDevicePresent: { _ in true }
        )
        let backend = LegacyCoreAudioBackend(listenerOperations: operations)
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        XCTAssertEqual(backend.stopMonitoring().count, 1)
        XCTAssertEqual(backend.listenerRegistrationCountForTesting, 1)
        XCTAssertTrue(backend.stopMonitoring().isEmpty)
        XCTAssertEqual(backend.listenerRegistrationCountForTesting, 0)
        XCTAssertEqual(removalCount, 2)
    }

    func testDisconnectedDeviceListenerRemovalFailureDoesNotBlockListenerRebuild() throws {
        var presenceResponses = [true, false]
        var removalCount = 0
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { _, _, _, _ in
                removalCount += 1
                return kAudioHardwareUnspecifiedError
            },
            isDevicePresent: { _ in
                presenceResponses.removeFirst()
            }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: { [] }
        )
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        XCTAssertNoThrow(try backend.rebuildListeners())
        XCTAssertEqual(
            backend.listenerRegistrationCountForTesting,
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.count
        )
        XCTAssertEqual(removalCount, 1)
    }

    func testValidListenerRemovalFailureIsRetainedWhileNewListenersAreReconciled() throws {
        var liveDeviceRemovalCount = 0
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { objectID, _, _, _ in
                guard objectID == 42 else { return noErr }
                liveDeviceRemovalCount += 1
                return liveDeviceRemovalCount == 1
                    ? kAudioHardwareUnspecifiedError
                    : noErr
            },
            isDevicePresent: { objectID in objectID == 42 }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: { [] }
        )
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        XCTAssertNoThrow(try backend.rebuildListeners())
        XCTAssertEqual(
            backend.listenerRegistrationCountForTesting,
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.count + 1
        )

        XCTAssertNoThrow(try backend.rebuildListeners())
        XCTAssertEqual(liveDeviceRemovalCount, 2)
        XCTAssertEqual(
            backend.listenerRegistrationCountForTesting,
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.count
        )
    }

    func testValidListenerRemovalRetriesAreDelayedAndBounded() async throws {
        var liveDeviceRemovalCount = 0
        let retryWindowExhausted = expectation(
            description: "initial removal and three bounded retries complete"
        )
        retryWindowExhausted.expectedFulfillmentCount = 4
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { objectID, _, _, _ in
                guard objectID == 42 else { return noErr }
                liveDeviceRemovalCount += 1
                retryWindowExhausted.fulfill()
                return kAudioHardwareUnspecifiedError
            },
            isDevicePresent: { objectID in objectID == 42 }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: { [] },
            listenerCleanupRetrySleep: { _ in await Task.yield() }
        )
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        try backend.rebuildListeners()
        await fulfillment(of: [retryWindowExhausted])
        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertEqual(liveDeviceRemovalCount, 4)
        XCTAssertEqual(
            backend.listenerRegistrationCountForTesting,
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.count + 1
        )
    }

    func testListenerCleanupRetryContinuesAfterTransientInventoryReadFailure() async throws {
        var liveDeviceRemovalCount = 0
        var inventoryReadCount = 0
        let retryWindowExhausted = expectation(
            description: "retry window survives a transient inventory read failure"
        )
        retryWindowExhausted.expectedFulfillmentCount = 4
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { objectID, _, _, _ in
                guard objectID == 42 else { return noErr }
                liveDeviceRemovalCount += 1
                retryWindowExhausted.fulfill()
                return kAudioHardwareUnspecifiedError
            },
            isDevicePresent: { objectID in objectID == 42 }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: {
                inventoryReadCount += 1
                if inventoryReadCount == 2 {
                    throw CoreAudioBackendFailure(
                        operation: "Injected transient device-list read",
                        status: kAudioHardwareUnspecifiedError
                    )
                }
                return []
            },
            listenerCleanupRetrySleep: { _ in await Task.yield() }
        )
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        try backend.rebuildListeners()
        await fulfillment(of: [retryWindowExhausted])
        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertEqual(liveDeviceRemovalCount, 4)
        XCTAssertEqual(inventoryReadCount, 4)
        XCTAssertFalse(backend.listenerCleanupRetryScheduledForTesting)
    }

    func testTransientListenerAddFailureIsRetriedWithoutDuplicates() async {
        var defaultOutputAddCount = 0
        let defaultOutputListenerInstalled = expectation(
            description: "default output listener succeeds during bounded retry"
        )
        let operations = CoreAudioListenerOperations(
            add: { _, address, _, _ in
                guard address.pointee.mSelector
                    == kAudioHardwarePropertyDefaultOutputDevice else {
                    return noErr
                }
                defaultOutputAddCount += 1
                if defaultOutputAddCount == 1 {
                    return kAudioHardwareUnspecifiedError
                }
                defaultOutputListenerInstalled.fulfill()
                return noErr
            },
            remove: { _, _, _, _ in noErr },
            isDevicePresent: { _ in true }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: { [] },
            listenerCleanupRetrySleep: { _ in await Task.yield() }
        )

        XCTAssertThrowsError(try backend.rebuildListeners())
        XCTAssertTrue(backend.listenerCleanupRetryScheduledForTesting)

        await fulfillment(of: [defaultOutputListenerInstalled])
        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertEqual(defaultOutputAddCount, 2)
        XCTAssertEqual(
            backend.listenerRegistrationCountForTesting,
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.count
        )
        XCTAssertFalse(backend.listenerCleanupRetryScheduledForTesting)
    }

    func testShutdownCancelsScheduledListenerCleanupRetry() async throws {
        var liveDeviceRemovalCount = 0
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { objectID, _, _, _ in
                guard objectID == 42 else { return noErr }
                liveDeviceRemovalCount += 1
                return kAudioHardwareUnspecifiedError
            },
            isDevicePresent: { objectID in objectID == 42 }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: { [] }
        )
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        try backend.rebuildListeners()
        XCTAssertTrue(backend.listenerCleanupRetryScheduledForTesting)

        XCTAssertEqual(backend.shutdown().count, 1)
        XCTAssertFalse(backend.listenerCleanupRetryScheduledForTesting)
        for _ in 0..<5 {
            await Task.yield()
        }
        XCTAssertEqual(liveDeviceRemovalCount, 2)
    }

    func testDisconnectedDeviceBufferRestoreIsTerminalAndDoesNotFailCleanup() {
        let restore = BufferFrameSizeRestore(
            deviceUID: AudioDeviceUID(rawValue: "output.disconnected"),
            frameCount: 512,
            appliedFrameCount: 64
        )
        var attemptCount = 0

        let restoreResult = LegacyCoreAudioBackend.reconcileBufferFrameSizeRestores(
            [restore],
            attemptRestore: { _ in
                attemptCount += 1
                throw CoreAudioBackendFailure(
                    operation: "Injected disconnected-device restoration",
                    status: kAudioHardwareBadDeviceError
                )
            },
            isDevicePresent: { _ in false }
        )

        XCTAssertTrue(restoreResult.failures.isEmpty)
        XCTAssertTrue(restoreResult.retryableRestores.isEmpty)
        XCTAssertEqual(attemptCount, 1)
    }

    func testValidDeviceBufferRestoreFailureRemainsRetryable() {
        let restore = BufferFrameSizeRestore(
            deviceUID: AudioDeviceUID(rawValue: "output.present"),
            frameCount: 512,
            appliedFrameCount: 64
        )
        var shouldFail = true
        var attemptCount = 0
        let attemptRestore: (BufferFrameSizeRestore) throws -> Void = { _ in
            attemptCount += 1
            if shouldFail {
                throw CoreAudioBackendFailure(
                    operation: "Injected live-device restoration",
                    status: kAudioHardwareUnspecifiedError
                )
            }
        }

        let firstResult = LegacyCoreAudioBackend.reconcileBufferFrameSizeRestores(
            [restore],
            attemptRestore: attemptRestore,
            isDevicePresent: { _ in true }
        )
        XCTAssertEqual(firstResult.retryableRestores, [restore])
        XCTAssertEqual(firstResult.failures.count, 1)

        shouldFail = false
        let retryResult = LegacyCoreAudioBackend.reconcileBufferFrameSizeRestores(
            firstResult.retryableRestores,
            attemptRestore: attemptRestore,
            isDevicePresent: { _ in true }
        )
        XCTAssertTrue(retryResult.retryableRestores.isEmpty)
        XCTAssertTrue(retryResult.failures.isEmpty)
        XCTAssertEqual(attemptCount, 2)
    }

    func testSystemDefaultOutputIsMonitoredDirectly() {
        XCTAssertTrue(
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.contains {
                $0.mSelector == kAudioHardwarePropertyDefaultOutputDevice
            }
        )
    }

    func testStreamConfigurationIsMonitoredOnInputAndOutputScopes() {
        let streamAddresses = LegacyCoreAudioBackend.monitoredDevicePropertyAddresses.filter {
            $0.mSelector == kAudioDevicePropertyStreamConfiguration
        }

        XCTAssertEqual(streamAddresses.count, 2)
        XCTAssertEqual(
            Set(streamAddresses.map(\.mScope)),
            Set([kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput])
        )
    }

    func testDuplicateNormalizedNamesUseUIDAsStableTieBreaker() {
        let laterUID = makeDevice(uid: "device.b", name: " Audio Device ")
        let earlierUID = makeDevice(uid: "device.a", name: "audio device")

        let sorted = LegacyCoreAudioBackend.sortedDevices([laterUID, earlierUID])

        XCTAssertEqual(sorted.map(\.id.rawValue), ["device.a", "device.b"])
    }

    private func makeDevice(uid: String, name: String) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: name,
            inputChannelCount: 2,
            outputChannelCount: 2,
            isAlive: true,
            currentNominalSampleRate: 48_000,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 48_000, maximum: 48_000),
            ]
        )
    }
}
