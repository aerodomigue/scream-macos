@testable import ScreamBar
import XCTest

@MainActor
final class CoreAudioDeviceServiceTests: XCTestCase {
    func testMissingPreferredOutputFallsBackThenRestoresWithoutChangingSelection() async throws {
        let defaultOutput = makeDevice(uid: "output.default", supportsInput: false)
        let preferredOutput = makeDevice(uid: "output.preferred", supportsInput: false)
        let input = makeDevice(uid: "input", supportsOutput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, defaultOutput], input: input, output: defaultOutput)
        )
        let service = makeService(backend: backend)
        let preferredSelection = AudioDeviceSelection.device(
            uid: preferredOutput.id,
            lastKnownName: preferredOutput.name
        )

        let fallbackRoute = try await service.prepareRoute(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: preferredSelection
        )
        XCTAssertEqual(fallbackRoute.route.output.id, defaultOutput.id)
        XCTAssertTrue(fallbackRoute.route.isUsingOutputFallback)

        backend.snapshot = makeSnapshot(
            devices: [input, defaultOutput, preferredOutput],
            input: input,
            output: defaultOutput
        )
        let restoredRoute = try await service.prepareRoute(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: preferredSelection
        )
        XCTAssertEqual(restoredRoute.route.output.id, preferredOutput.id)
        XCTAssertFalse(restoredRoute.route.isUsingOutputFallback)
    }

    func testPresentButIncompatiblePreferredOutputDoesNotFallBack() async {
        let defaultOutput = makeDevice(uid: "output.default", supportsInput: false)
        let incompatibleOutput = makeDevice(
            uid: "output.incompatible",
            supportsInput: false,
            sampleRate: 44_100
        )
        let input = makeDevice(uid: "input", supportsOutput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, defaultOutput, incompatibleOutput],
                input: input,
                output: defaultOutput
            )
        )
        let service = makeService(backend: backend)

        do {
            _ = try await service.prepareRoute(
                inputSelection: .device(uid: input.id, lastKnownName: input.name),
                outputSelection: .device(
                    uid: incompatibleOutput.id,
                    lastKnownName: incompatibleOutput.name
                )
            )
            XCTFail("Expected incompatible preferred output to fail")
        } catch AudioRoutingError.noCommonSampleRate {
            XCTAssertTrue(backend.preparedRoutes.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSameDeviceRouteIsPreparedOnceAtNegotiatedRate() async throws {
        let fullDuplexDevice = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [fullDuplexDevice],
                input: fullDuplexDevice,
                output: fullDuplexDevice
            )
        )
        let service = makeService(backend: backend)

        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )

        XCTAssertEqual(route.route.input.id, fullDuplexDevice.id)
        XCTAssertEqual(route.route.output.id, fullDuplexDevice.id)
        XCTAssertEqual(route.route.nominalSampleRate, 48_000)
        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.sampleRateWrites.isEmpty)
    }

    func testExplicitBufferFrameSizeIsForwardedToBackend() async throws {
        let fullDuplexDevice = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [fullDuplexDevice],
                input: fullDuplexDevice,
                output: fullDuplexDevice
            )
        )
        let service = makeService(backend: backend)

        _ = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault,
            requestedBufferFrameSize: 128
        )

        XCTAssertEqual(backend.preparedRoutes.first?.requestedBufferFrameSize, 128)
    }

    func testStalePreparationDrainsBeforeReplacementMutatesHardware() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 44_100,
            supportedRates: [44_100, 48_000]
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 48_000,
            supportedRates: [44_100, 48_000]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, output], input: input, output: output)
        )
        backend.appliesSampleRateWritesImmediately = false
        let timing = ControlledCoreAudioTiming()
        let service = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend,
            timing: timing.makeTiming()
        )
        var firstRevisionIsCurrent = true

        let firstTask = Task {
            try await service.prepareRoute(
                inputSelection: .systemDefault,
                outputSelection: .systemDefault,
                preparationToken: UUID(),
                isRevisionCurrent: { firstRevisionIsCurrent }
            )
        }
        await timing.waitUntilSuspended()
        XCTAssertEqual(backend.sampleRateWrites.count, 1)

        firstRevisionIsCurrent = false
        let replacementTask = Task {
            try await service.prepareRoute(
                inputSelection: .systemDefault,
                outputSelection: .systemDefault,
                preparationToken: UUID(),
                isRevisionCurrent: { true }
            )
        }
        await Task.yield()
        XCTAssertEqual(backend.sampleRateWrites.count, 1)
        XCTAssertTrue(backend.preparedRoutes.isEmpty)

        backend.applyRate(48_000, to: input.id)
        timing.resume()

        do {
            _ = try await firstTask.value
            XCTFail("Expected stale preparation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected stale preparation error: \(error)")
        }
        _ = try await replacementTask.value
        XCTAssertEqual(backend.preparedRoutes.count, 1)
    }

    func testFinalValidationFailureDestroysPreparedSession() async {
        let input = makeDevice(uid: "input", supportsOutput: false)
        let output = makeDevice(uid: "output", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, output], input: input, output: output)
        )
        backend.snapshotAfterPrepare = AudioHardwareSnapshot(
            revision: 2,
            devices: [input],
            defaultInputUID: input.id,
            defaultOutputUID: nil
        )
        let service = makeService(backend: backend)

        do {
            _ = try await service.prepareRoute(
                inputSelection: .systemDefault,
                outputSelection: .systemDefault
            )
            XCTFail("Expected final route validation failure")
        } catch AudioRoutingError.finalRouteValidationFailed {
            XCTAssertEqual(backend.stoppedSessionIDs, [backend.lastPreparedSessionID])
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
    }

    func testTerminationWaitsForSuspendedPreparationToDrain() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 44_100,
            supportedRates: [44_100, 48_000]
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 48_000,
            supportedRates: [44_100, 48_000]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, output], input: input, output: output)
        )
        backend.appliesSampleRateWritesImmediately = false
        let timing = ControlledCoreAudioTiming()
        let deviceService = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend,
            timing: timing.makeTiming()
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: deviceService,
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(configuration: DirectRoutingConfiguration())
        await timing.waitUntilSuspended()

        var shutdownCompleted = false
        let shutdownTask = Task {
            _ = await routingService.shutdownAndWait()
            shutdownCompleted = true
        }
        await Task.yield()
        XCTAssertTrue(routingService.isShuttingDown)
        XCTAssertFalse(shutdownCompleted)

        timing.resume()
        await shutdownTask.value

        XCTAssertTrue(shutdownCompleted)
        XCTAssertTrue(backend.preparedRoutes.isEmpty)
        XCTAssertEqual(backend.shutdownCount, 1)
        XCTAssertEqual(backend.rebuildListenersCount, 0)
    }

    func testStartStopStartCreatesNoOverlappingRoute() async throws {
        let device = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [device], input: device, output: device)
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()
        guard case .running = routingService.state else {
            return XCTFail("Expected first route to run")
        }

        try await routingService.stopAndWait()
        XCTAssertEqual(routingService.state, .stopped)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)

        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()
        guard case .running = routingService.state else {
            return XCTFail("Expected replacement route to run")
        }
        XCTAssertEqual(backend.preparedRoutes.count, 2)
        XCTAssertEqual(backend.startedSessionIDs.count, 2)
    }

    func testPermissionRevocationStopsActiveRouteAndReportsDenial() async throws {
        let device = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [device], input: device, output: device)
        )
        let permission = AudioInputPermissionSpy()
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: permission
        )

        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()
        guard case .running = routingService.state else {
            return XCTFail("Expected route to run before revocation")
        }

        permission.isGranted = false
        routingService.revalidatePermissionIfRunning()
        await routingService.waitForIdle()

        XCTAssertEqual(routingService.state, .failed(.inputPermissionDenied))
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
    }

    func testChannelCountChangeNotificationTriggersFullRouteRebuild() async throws {
        let originalDevice = makeDevice(uid: "duplex", inputChannelCount: 2)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [originalDevice],
                input: originalDevice,
                output: originalDevice
            )
        )
        let timing = ControlledCoreAudioTiming()
        let deviceService = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend,
            timing: timing.makeTiming()
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: deviceService,
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()

        let rebuilt = expectation(description: "route rebuilt after channel change")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                rebuilt.fulfill()
            }
        }
        let changedDevice = makeDevice(uid: "duplex", inputChannelCount: 1)
        backend.snapshot = makeSnapshot(
            devices: [changedDevice],
            input: changedDevice,
            output: changedDevice
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [rebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
        XCTAssertEqual(backend.preparedRoutes.count, 2)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected rebuilt route to be running")
        }
        XCTAssertEqual(route.input.inputChannelCount, 1)
    }

    func testSystemDefaultFollowsReplacementAfterDefaultOutputDisappears() async throws {
        let input = makeDevice(uid: "Auna Mic", supportsOutput: false)
        let bose = makeDevice(uid: "Bose QC45", supportsInput: false)
        let speakers = makeDevice(uid: "Mac mini Speakers", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, bose], input: input, output: bose)
        )
        let timing = ControlledCoreAudioTiming()
        let deviceService = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend,
            timing: timing.makeTiming()
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: deviceService,
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()

        let rebuilt = expectation(description: "route rebuilt to replacement default output")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                rebuilt.fulfill()
            }
        }
        backend.snapshot = makeSnapshot(
            devices: [input, speakers],
            input: input,
            output: speakers
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [rebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.last?.output.id, speakers.id)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
        XCTAssertGreaterThan(deviceService.snapshot.revision, 1)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected replacement default route to run")
        }
        XCTAssertEqual(route.output.id, speakers.id)
        XCTAssertFalse(route.isUsingOutputFallback)
    }

    func testSystemDefaultReturnsToReconnectedDeviceWhenMacOSMakesItDefault() async throws {
        let input = makeDevice(uid: "Auna Mic", supportsOutput: false)
        let bose = makeDevice(uid: "Bose QC45", supportsInput: false)
        let speakers = makeDevice(uid: "Mac mini Speakers", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, speakers], input: input, output: speakers)
        )
        let timing = ControlledCoreAudioTiming()
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: CoreAudioDeviceService(
                logStore: RollingLogStore(),
                backend: backend,
                timing: timing.makeTiming()
            ),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()

        let rebuilt = expectation(description: "route rebuilt to reconnected default output")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                rebuilt.fulfill()
            }
        }
        backend.snapshot = makeSnapshot(
            devices: [input, speakers, bose],
            input: input,
            output: bose
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [rebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.last?.output.id, bose.id)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected reconnected default route to run")
        }
        XCTAssertEqual(route.output.id, bose.id)
        XCTAssertFalse(route.isUsingOutputFallback)
    }

    func testExplicitOutputSelectionKeepsItsExistingFallbackPolicy() async throws {
        let input = makeDevice(uid: "Auna Mic", supportsOutput: false)
        let bose = makeDevice(uid: "Bose QC45", supportsInput: false)
        let speakers = makeDevice(uid: "Mac mini Speakers", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, bose, speakers], input: input, output: speakers)
        )
        let timing = ControlledCoreAudioTiming()
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: CoreAudioDeviceService(
                logStore: RollingLogStore(),
                backend: backend,
                timing: timing.makeTiming()
            ),
            permissionService: AudioInputPermissionSpy()
        )
        let boseSelection = AudioDeviceSelection.device(uid: bose.id, lastKnownName: bose.name)
        routingService.start(
            configuration: DirectRoutingConfiguration(outputSelection: boseSelection)
        )
        await routingService.waitForIdle()

        let fallbackRebuilt = expectation(description: "explicit device falls back when unavailable")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                fallbackRebuilt.fulfill()
            }
        }
        backend.snapshot = makeSnapshot(
            devices: [input, speakers],
            input: input,
            output: speakers
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [fallbackRebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.last?.output.id, speakers.id)

        let preferredRebuilt = expectation(description: "explicit device restores when available")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 3 {
                preferredRebuilt.fulfill()
            }
        }
        backend.snapshot = makeSnapshot(
            devices: [input, speakers, bose],
            input: input,
            output: speakers
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [preferredRebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.last?.output.id, bose.id)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected explicit device route to run")
        }
        XCTAssertEqual(route.output.id, bose.id)
        XCTAssertFalse(route.isUsingOutputFallback)
    }

    func testRapidDefaultOutputChangesCoalesceToLatestDefault() async throws {
        let input = makeDevice(uid: "Auna Mic", supportsOutput: false)
        let bose = makeDevice(uid: "Bose QC45", supportsInput: false)
        let speakers = makeDevice(uid: "Mac mini Speakers", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, bose, speakers], input: input, output: bose)
        )
        let timing = ControlledCoreAudioTiming()
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: CoreAudioDeviceService(
                logStore: RollingLogStore(),
                backend: backend,
                timing: timing.makeTiming()
            ),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()

        let rebuilt = expectation(description: "single route rebuild for latest default output")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                rebuilt.fulfill()
            }
        }
        backend.snapshot = makeSnapshot(
            devices: [input, bose, speakers],
            input: input,
            output: speakers
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended(count: 1)

        backend.snapshot = makeSnapshot(
            devices: [input, bose, speakers],
            input: input,
            output: bose
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended(count: 2)

        backend.snapshot = makeSnapshot(
            devices: [input, bose, speakers],
            input: input,
            output: speakers
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended(count: 3)
        timing.resume()

        await fulfillment(of: [rebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.count, 2)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
        XCTAssertEqual(backend.preparedRoutes.last?.output.id, speakers.id)
    }

    func testEquivalentReorderedSampleRateRangesDoNotTriggerRouteRebuild() async throws {
        let originalDevice = makeDevice(
            uid: "duplex",
            nominalRanges: [
                NominalSampleRateRange(minimum: 44_100, maximum: 60_000),
                NominalSampleRateRange(minimum: 60_000, maximum: 96_000),
            ]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [originalDevice],
                input: originalDevice,
                output: originalDevice
            )
        )
        let timing = ControlledCoreAudioTiming()
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: CoreAudioDeviceService(
                logStore: RollingLogStore(),
                backend: backend,
                timing: timing.makeTiming()
            ),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()

        let snapshotRefreshed = expectation(description: "equivalent snapshot refreshed")
        backend.onMakeSnapshot = snapshotRefreshed.fulfill
        let reorderedDevice = makeDevice(
            uid: "duplex",
            nominalRanges: [
                NominalSampleRateRange(minimum: 70_000, maximum: 96_000),
                NominalSampleRateRange(minimum: 44_100, maximum: 70_000),
            ]
        )
        backend.snapshot = makeSnapshot(
            devices: [reorderedDevice],
            input: reorderedDevice,
            output: reorderedDevice
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [snapshotRefreshed])
        await routingService.waitForIdle()

        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        guard case .running = routingService.state else {
            return XCTFail("Expected the original route to remain active")
        }
    }

    func testFailedDirectRouteCleanupIsRetainedAndCanBeRetried() async throws {
        let device = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [device], input: device, output: device)
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()
        backend.cleanupFailureBatches = [["Injected AUHAL teardown failure"], []]

        do {
            try await routingService.stopAndWait()
            XCTFail("Expected the first cleanup attempt to fail")
        } catch AudioRoutingError.cleanupFailed {
            guard case .failed(.cleanupFailed) = routingService.state else {
                return XCTFail("Expected a cleanup failure state")
            }
        }

        try await routingService.stopAndWait()
        XCTAssertEqual(routingService.state, .stopped)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 2)
    }

    func testDirectStopDoesNotCompleteWhileBackendRetainsResources() async throws {
        let device = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [device], input: device, output: device)
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()
        backend.unreleasedResourceFailures = ["Direct: pending route resources remain registered"]

        do {
            try await routingService.stopAndWait()
            XCTFail("Expected retained backend resources to block Direct teardown")
        } catch AudioRoutingError.cleanupFailed {
            XCTAssertEqual(
                routingService.state,
                .failed(.cleanupFailed(["Direct: pending route resources remain registered"]))
            )
        } catch {
            XCTFail("Unexpected teardown error: \(error)")
        }
    }

    func testStartFailureRemainsPrimaryWhenItsCleanupAlsoFails() async throws {
        let device = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [device], input: device, output: device)
        )
        backend.startError = CoreAudioBackendFailure(operation: "Injected start", status: -1)
        backend.cleanupFailureBatches = [["Injected teardown failure"], []]
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(configuration: DirectRoutingConfiguration())
        await routingService.waitForIdle()

        let expectedContext = AUHALContext(
            inputUID: device.id,
            outputUID: device.id,
            nominalSampleRate: device.currentNominalSampleRate
        )
        XCTAssertEqual(routingService.state, .failed(.auHALStartFailed(expectedContext)))

        backend.startError = nil
        try await routingService.stopAndWait()
        XCTAssertEqual(routingService.state, .stopped)
    }

    private func makeService(backend: CoreAudioBackendSpy) -> CoreAudioDeviceService {
        CoreAudioDeviceService(logStore: RollingLogStore(), backend: backend)
    }

    private func makeDevice(
        uid: String,
        supportsInput: Bool = true,
        supportsOutput: Bool = true,
        sampleRate: Double = 48_000,
        supportedRates: [Double]? = nil,
        nominalRanges: [NominalSampleRateRange]? = nil,
        inputChannelCount: Int = 2
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: uid,
            inputChannelCount: supportsInput ? inputChannelCount : 0,
            outputChannelCount: supportsOutput ? 2 : 0,
            isAlive: true,
            currentNominalSampleRate: sampleRate,
            supportedNominalSampleRates: nominalRanges
                ?? (supportedRates ?? [sampleRate]).map {
                    NominalSampleRateRange(minimum: $0, maximum: $0)
                },
            currentBufferFrameSize: 512,
            supportedBufferFrameSizeRange: AudioBufferFrameSizeRange(
                minimum: 64,
                maximum: 2_048
            )
        )
    }

    private func makeSnapshot(
        devices: [AudioDeviceDescriptor],
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) -> AudioHardwareSnapshot {
        AudioHardwareSnapshot(
            revision: 1,
            devices: devices,
            defaultInputUID: input.id,
            defaultOutputUID: output.id
        )
    }
}

@MainActor
private final class CoreAudioBackendSpy: CoreAudioBackend {
    struct PreparedRouteCall: Equatable {
        let input: AudioDeviceDescriptor
        let output: AudioDeviceDescriptor
        let nominalSampleRate: Double
        let requestedBufferFrameSize: UInt32?
    }

    var onHardwareChanged: (() -> Void)?
    var snapshot: AudioHardwareSnapshot {
        didSet {
            for device in snapshot.devices where rates[device.id] == nil {
                rates[device.id] = device.currentNominalSampleRate
            }
        }
    }
    private(set) var sampleRateWrites: [(uid: AudioDeviceUID, rate: Double)] = []
    private(set) var preparedRoutes: [PreparedRouteCall] = []
    private(set) var stoppedSessionIDs: [UUID] = []
    private(set) var startedSessionIDs: [UUID] = []
    private(set) var shutdownCount = 0
    private(set) var rebuildListenersCount = 0
    private(set) var lastPreparedSessionID: UUID?
    var snapshotAfterPrepare: AudioHardwareSnapshot?
    var appliesSampleRateWritesImmediately = true
    var onPrepareRoute: (() -> Void)?
    var onMakeSnapshot: (() -> Void)?
    var cleanupFailureBatches: [[String]] = []
    var unreleasedResourceFailures: [String] = []
    var startError: Error?
    private var rates: [AudioDeviceUID: Double]

    init(snapshot: AudioHardwareSnapshot) {
        self.snapshot = snapshot
        self.rates = Dictionary(
            uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0.currentNominalSampleRate) }
        )
    }

    func startMonitoring() throws {}

    func stopMonitoring() -> [String] { [] }

    func rebuildListeners() throws {
        rebuildListenersCount += 1
    }

    func makeSnapshot(revision: UInt64) throws -> AudioHardwareSnapshot {
        let refreshedSnapshot = AudioHardwareSnapshot(
            revision: revision,
            devices: snapshot.devices.map { descriptor in
                AudioDeviceDescriptor(
                    id: descriptor.id,
                    name: descriptor.name,
                    inputChannelCount: descriptor.inputChannelCount,
                    outputChannelCount: descriptor.outputChannelCount,
                    isAlive: descriptor.isAlive,
                    currentNominalSampleRate: rates[descriptor.id]
                        ?? descriptor.currentNominalSampleRate,
                    supportedNominalSampleRates: NominalSampleRateNegotiator.normalizedRanges(
                        descriptor.supportedNominalSampleRates
                    ),
                    currentBufferFrameSize: descriptor.currentBufferFrameSize,
                    supportedBufferFrameSizeRange: descriptor.supportedBufferFrameSizeRange
                )
            },
            defaultInputUID: snapshot.defaultInputUID,
            defaultOutputUID: snapshot.defaultOutputUID
        )
        onMakeSnapshot?()
        return refreshedSnapshot
    }

    func currentNominalSampleRate(for uid: AudioDeviceUID) throws -> Double {
        guard let rate = rates[uid] else {
            throw CoreAudioBackendFailure(operation: "Read test rate", status: -1)
        }
        return rate
    }

    func setNominalSampleRate(_ rate: Double, for uid: AudioDeviceUID) throws {
        if appliesSampleRateWritesImmediately {
            rates[uid] = rate
        }
        sampleRateWrites.append((uid: uid, rate: rate))
    }

    func isAlive(uid: AudioDeviceUID) throws -> Bool {
        snapshot.devices.first { $0.id == uid }?.isAlive ?? false
    }

    func prepareRoute(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?,
        validateOwnership: () throws -> Void
    ) throws -> UUID {
        try validateOwnership()
        preparedRoutes.append(
            PreparedRouteCall(
                input: input,
                output: output,
                nominalSampleRate: nominalSampleRate,
                requestedBufferFrameSize: requestedBufferFrameSize
            )
        )
        let sessionID = UUID()
        lastPreparedSessionID = sessionID
        if let snapshotAfterPrepare {
            snapshot = snapshotAfterPrepare
        }
        onPrepareRoute?()
        return sessionID
    }

    func startRoute(sessionID: UUID) throws {
        startedSessionIDs.append(sessionID)
        if let startError {
            throw startError
        }
    }

    func stopAndDestroyRoute(sessionID: UUID) -> [String] {
        stoppedSessionIDs.append(sessionID)
        guard !cleanupFailureBatches.isEmpty else { return [] }
        return cleanupFailureBatches.removeFirst()
    }

    func verifyRouteResourcesReleased() -> [String] {
        unreleasedResourceFailures
    }

    func shutdown() -> [String] {
        shutdownCount += 1
        return []
    }

    func applyRate(_ rate: Double, to uid: AudioDeviceUID) {
        rates[uid] = rate
    }

    func emitHardwareChange() {
        onHardwareChanged?()
    }
}

@MainActor
private final class AudioInputPermissionSpy: AudioInputPermissionServicing {
    var isGranted = true

    func requestPermissionIfNeeded() async throws {
        guard isGranted else {
            throw AudioRoutingError.inputPermissionDenied
        }
    }
}

@MainActor
private final class ControlledCoreAudioTiming {
    private struct SuspendedWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var suspensionContinuations: [CheckedContinuation<Void, Error>] = []
    private var suspendedWaiters: [SuspendedWaiter] = []

    func makeTiming() -> CoreAudioServiceTiming {
        CoreAudioServiceTiming(
            sleep: { [weak self] _ in
                guard let self else { throw CancellationError() }
                try await withCheckedThrowingContinuation { continuation in
                    self.suspensionContinuations.append(continuation)
                    self.resumeSuspendedWaitersIfNeeded()
                }
            }
        )
    }

    func waitUntilSuspended(count: Int = 1) async {
        if suspensionContinuations.count >= count { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(
                SuspendedWaiter(count: count, continuation: continuation)
            )
        }
    }

    func resume() {
        let continuations = suspensionContinuations
        suspensionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumeSuspendedWaitersIfNeeded() {
        let readyWaiters = suspendedWaiters.filter {
            suspensionContinuations.count >= $0.count
        }
        suspendedWaiters.removeAll {
            suspensionContinuations.count >= $0.count
        }
        readyWaiters.forEach { $0.continuation.resume() }
    }
}
