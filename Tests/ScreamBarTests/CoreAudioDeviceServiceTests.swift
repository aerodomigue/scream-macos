@testable import ScreamBar
import AudioToolbox
import CoreAudio
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

    func testPresentPreferredOutputWithoutCommonRateUsesConversionWithoutFallback() async throws {
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

        let route = try await service.prepareRoute(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: .device(
                uid: incompatibleOutput.id,
                lastKnownName: incompatibleOutput.name
            )
        )

        XCTAssertEqual(route.route.output.id, incompatibleOutput.id)
        XCTAssertFalse(route.route.isUsingOutputFallback)
        XCTAssertEqual(
            route.route.sampleRatePlan,
            .converted(inputSampleRate: 48_000, outputSampleRate: 44_100)
        )
        XCTAssertEqual(backend.preparedRoutes.first?.sampleRatePlan, route.route.sampleRatePlan)
        XCTAssertEqual(backend.preparedRoutes.first?.requestedBufferFrameSize, 64)
        XCTAssertEqual(route.route.bufferFrameSize, 64)
    }

    func testPreparedRoutePublishesPostConfigurationPhysicalFormats() async throws {
        let initialInput = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 44_100,
            supportedRates: [44_100, 48_000],
            inputPhysicalStreamFormats: [makePhysicalFormat(sampleRate: 44_100)]
        )
        let refreshedInput = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            supportedRates: [44_100, 48_000],
            inputPhysicalStreamFormats: [makePhysicalFormat(sampleRate: 48_000)]
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 48_000,
            outputPhysicalStreamFormats: [makePhysicalFormat(sampleRate: 48_000)]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [initialInput, output],
                input: initialInput,
                output: output
            )
        )
        backend.snapshotAfterPrepare = makeSnapshot(
            devices: [refreshedInput, output],
            input: refreshedInput,
            output: output
        )
        let service = makeService(backend: backend)

        let preparedRoute = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )

        XCTAssertEqual(
            preparedRoute.route.input.primaryInputPhysicalStreamFormat?
                .sampleRate,
            48_000
        )
        XCTAssertEqual(
            preparedRoute.route.output.primaryOutputPhysicalStreamFormat?
                .sampleRate,
            48_000
        )
    }

    func testAutomaticConvertedRouteEscalatesBufferAfterRuntimeDisruption() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        let logStore = RollingLogStore()
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.004,
            maximumApplicationSeconds: 0.005,
            isLowLatency: true,
            requiresBufferEscalation: true,
            bufferEscalationReason: "FIFO underruns at latency ceiling: 1"
        )
        let rebuilt = expectation(description: "route rebuilt at the next buffer tier")
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 2 else { return }
            backend.routeLatencyValue = CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0.011,
                maximumApplicationSeconds: 0.018,
                isLowLatency: false,
                requiresBufferEscalation: false
            )
            rebuilt.fulfill()
        }
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await fulfillment(of: [rebuilt], timeout: 2)
        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128]
        )
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message.contains("FIFO underruns at latency ceiling: 1")
            }
        )
        try await routingService.stopAndWait()
    }

    func testRelaxedAutomaticSensitivityEscalatesOnFourthEpisodeInTenSeconds() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        let healthyLatency = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.004,
            maximumApplicationSeconds: 0.005,
            isLowLatency: true,
            requiresBufferEscalation: false
        )
        backend.routeLatencyValue = healthyLatency
        let logStore = RollingLogStore()
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .relaxed
            )
        )
        await routingService.waitForIdle()

        var cumulativeIncidentCount: UInt64 = 0
        var monitorPollCount = 0
        backend.routeLatencyProvider = { sessionID in
            guard backend.startedSessionIDs.contains(sessionID) else {
                return healthyLatency
            }
            monitorPollCount += 1
            guard monitorPollCount.isMultiple(of: 2) == false else {
                return CoreAudioRouteLatency(
                    estimatedApplicationSeconds: 0.004,
                    maximumApplicationSeconds: 0.005,
                    isLowLatency: true,
                    requiresBufferEscalation: false,
                    bufferEscalationIncidentCount: cumulativeIncidentCount
                )
            }
            cumulativeIncidentCount += 1
            return CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0.006,
                maximumApplicationSeconds: 0.009,
                isLowLatency: true,
                requiresBufferEscalation: true,
                bufferEscalationReason:
                    "injected runtime incidents: \(cumulativeIncidentCount)",
                bufferEscalationIncidentCount: cumulativeIncidentCount
            )
        }
        let rebuilt = expectation(
            description: "relaxed sensitivity rebuilds on the fourth episode"
        )
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 2 else { return }
            backend.routeLatencyProvider = nil
            backend.routeLatencyValue = healthyLatency
            rebuilt.fulfill()
        }

        await fulfillment(of: [rebuilt], timeout: 5)
        await routingService.waitForIdle()

        XCTAssertEqual(cumulativeIncidentCount, 4)
        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128]
        )
        XCTAssertEqual(
            logStore.entries.filter {
                $0.message.contains(
                    "Relaxed automatic buffer sensitivity recorded episode"
                )
            }.count,
            3
        )
        try await routingService.stopAndWait()
    }

    func testRelaxedAutomaticSensitivityTreatsOverflowBurstAsOneEpisode() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        let healthyLatency = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.004,
            maximumApplicationSeconds: 0.005,
            isLowLatency: true,
            requiresBufferEscalation: false
        )
        backend.routeLatencyValue = healthyLatency
        let logStore = RollingLogStore()
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .relaxed
            )
        )
        await routingService.waitForIdle()

        var monitorPollCount = 0
        backend.routeLatencyProvider = { sessionID in
            guard backend.startedSessionIDs.contains(sessionID) else {
                return healthyLatency
            }
            monitorPollCount += 1
            guard monitorPollCount == 1 else {
                return CoreAudioRouteLatency(
                    estimatedApplicationSeconds: 0.004,
                    maximumApplicationSeconds: 0.005,
                    isLowLatency: true,
                    requiresBufferEscalation: false,
                    bufferEscalationIncidentCount: 16
                )
            }
            return CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0.006,
                maximumApplicationSeconds: 0.009,
                isLowLatency: true,
                requiresBufferEscalation: true,
                bufferEscalationReason:
                    "FIFO writes above latency ceiling: 16, dropped input frames: 996",
                bufferEscalationIncidentCount: 16
            )
        }

        try await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        XCTAssertEqual(backend.stabilityCheckpointSessionIDs.count, 1)
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message.contains("recorded episode 1 of 3")
                    && $0.message.contains("16 low-level events")
            }
        )
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message == "Relaxed automatic buffer episode recovered"
            }
        )
        try await routingService.stopAndWait()
    }

    func testChangingAutomaticSensitivityDoesNotRebuildRunningRoute() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )
        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .relaxed
            )
        )
        await routingService.waitForIdle()

        routingService.configurationDidChange(
            DirectRoutingConfiguration(automaticSensitivity: .strict)
        )

        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        XCTAssertEqual(backend.stabilityCheckpointSessionIDs.count, 1)
        guard case .running = routingService.state else {
            return XCTFail("Expected sensitivity change to preserve the route")
        }
        try await routingService.stopAndWait()
    }

    func testAutomaticConvertedRouteExhaustsEveryBufferTierBeforeFailing() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            maximumBufferFrameSize: 512
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100,
            maximumBufferFrameSize: 512
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.035,
            maximumApplicationSeconds: 0.050,
            isLowLatency: false,
            requiresBufferEscalation: true,
            bufferEscalationReason: "persistent injected instability"
        )
        let terminalStop = expectation(
            description: "route stopped after exhausting every buffer tier"
        )
        let logStore = RollingLogStore()
        backend.onStopRoute = {
            guard backend.stoppedSessionIDs.count == 4 else { return }
            terminalStop.fulfill()
        }
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await fulfillment(of: [terminalStop], timeout: 4)
        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128, 256, 512]
        )
        XCTAssertEqual(backend.startedSessionIDs.count, 4)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 4)
        XCTAssertFalse(routingService.desiredRunning)
        guard case .failed(.latencyStabilityLimitExceeded(let context)) =
            routingService.state else {
            return XCTFail("Expected a terminal latency stability failure")
        }
        XCTAssertEqual(context.bufferFrameCount, 512)
        XCTAssertEqual(context.estimatedApplicationLatencySeconds, 0.035)
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message == "Direct Routing stopping after the automatic buffer ladder was exhausted (buffer tier: 512 frames, app latency: 35.0 ms, maximum: 50.0 ms, reason: persistent injected instability)"
            }
        )
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message.contains(
                    "buffer policy: automatic, effective tier: 64 frames"
                )
            }
        )
    }

    func testExplicitBufferInstabilityReportsPolicyWithoutClaimingLadderExhaustion() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.0089,
            maximumApplicationSeconds: 0.010,
            isLowLatency: true,
            requiresBufferEscalation: true,
            bufferEscalationReason: "callback execution exceeded its real-time deadline"
        )
        let stopped = expectation(description: "explicit unstable route stopped")
        backend.onStopRoute = { stopped.fulfill() }
        let logStore = RollingLogStore()
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(
            configuration: DirectRoutingConfiguration(bufferSize: .frames64)
        )
        await fulfillment(of: [stopped], timeout: 2)
        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64]
        )
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message == "Direct Routing stopping because the explicit 64-frame buffer became unstable (app latency: 8.9 ms, maximum: 10.0 ms, reason: callback execution exceeded its real-time deadline)"
            }
        )
        XCTAssertFalse(
            logStore.entries.contains {
                $0.message.contains("automatic buffer ladder was exhausted")
            }
        )
        XCTAssertTrue(
            logStore.entries.contains {
                $0.message.contains(
                    "buffer policy: explicit 64 frames, effective tier: 64 frames"
                )
            }
        )
    }

    func testAutomaticBufferEscalationResetsWhenEffectiveOutputChanges() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let firstOutput = makeDevice(
            uid: "output.first",
            supportsInput: false,
            sampleRate: 44_100
        )
        let replacementOutput = makeDevice(
            uid: "output.replacement",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, firstOutput],
                input: input,
                output: firstOutput
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.004,
            maximumApplicationSeconds: 0.005,
            isLowLatency: true,
            requiresBufferEscalation: true
        )
        let escalated = expectation(description: "first route escalated to 128 frames")
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 2 else { return }
            backend.routeLatencyValue = CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0.006,
                maximumApplicationSeconds: 0.009,
                isLowLatency: true,
                requiresBufferEscalation: false
            )
            escalated.fulfill()
        }
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

        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await fulfillment(of: [escalated], timeout: 2)
        await routingService.waitForIdle()

        let rebuilt = expectation(
            description: "replacement output starts from the lowest automatic tier"
        )
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 3 else { return }
            rebuilt.fulfill()
        }
        backend.snapshot = makeSnapshot(
            devices: [input, replacementOutput],
            input: input,
            output: replacementOutput
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [rebuilt], timeout: 2)
        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128, 64]
        )
        try await routingService.stopAndWait()
    }

    func testBufferCapabilityMetadataChangeDoesNotInterruptRunningRoute() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.004,
            maximumApplicationSeconds: 0.005,
            isLowLatency: true,
            requiresBufferEscalation: true
        )
        let escalated = expectation(description: "route escalated to 128 frames")
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 2 else { return }
            backend.routeLatencyValue = CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0.006,
                maximumApplicationSeconds: 0.009,
                isLowLatency: true,
                requiresBufferEscalation: false
            )
            escalated.fulfill()
        }
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

        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await fulfillment(of: [escalated], timeout: 2)
        await routingService.waitForIdle()

        let restrictedOutput = makeDevice(
            uid: output.id.rawValue,
            supportsInput: false,
            sampleRate: output.currentNominalSampleRate,
            currentBufferFrameSize: 64,
            minimumBufferFrameSize: 64,
            maximumBufferFrameSize: 64
        )
        backend.snapshot = makeSnapshot(
            devices: [input, restrictedOutput],
            input: input,
            output: restrictedOutput
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128]
        )
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected the existing route to remain running")
        }
        XCTAssertEqual(route.bufferFrameSize, 128)
        try await routingService.stopAndWait()
    }

    func testAutomaticConvertedRouteRetriesWhenInitialBufferCannotBeConfigured() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.prepareRouteErrors = [
            LegacyRouteFailure.bufferFrameSizeConfiguration(
                BufferFrameSizeConfigurationContext(
                    deviceUID: output.id,
                    requestedFrameCount: 64,
                    observedFrameCount: 512,
                    operation: "test rejection"
                )
            ),
        ]
        let rebuilt = expectation(description: "route retried at 128 frames")
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 2 else { return }
            rebuilt.fulfill()
        }
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(configuration: DirectRoutingConfiguration())
        await fulfillment(of: [rebuilt], timeout: 2)
        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128]
        )
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected the retried route to be running")
        }
        XCTAssertEqual(route.bufferFrameSize, 128)
        try await routingService.stopAndWait()
    }

    func testAutomaticRouteStopsWhenLastBufferTierRemainsUnstable() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            minimumBufferFrameSize: 512
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100,
            minimumBufferFrameSize: 512
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.035,
            maximumApplicationSeconds: 0.050,
            isLowLatency: false,
            requiresBufferEscalation: true
        )
        let stopped = expectation(description: "unstable last-tier route stopped")
        backend.onStopRoute = { stopped.fulfill() }
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertFalse(routingService.desiredRunning)
        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [512]
        )
        guard case .failed(.latencyStabilityLimitExceeded(let context)) =
            routingService.state else {
            return XCTFail("Expected an explicit latency stability failure")
        }
        XCTAssertEqual(context.bufferFrameCount, 512)
        XCTAssertEqual(context.estimatedApplicationLatencySeconds, 0.035)
    }

    func testAutomaticRouteWithoutSupportedTierStopsInsteadOfTryingInvalidBuffers() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            currentBufferFrameSize: 1_024,
            minimumBufferFrameSize: 1_024,
            maximumBufferFrameSize: 2_048
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100,
            currentBufferFrameSize: 1_024,
            minimumBufferFrameSize: 1_024,
            maximumBufferFrameSize: 2_048
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.080,
            maximumApplicationSeconds: 0.120,
            isLowLatency: false,
            requiresBufferEscalation: true
        )
        let stopped = expectation(
            description: "unstable native-buffer fallback route stopped"
        )
        backend.onStopRoute = { stopped.fulfill() }
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: makeService(backend: backend),
            permissionService: AudioInputPermissionSpy()
        )

        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [nil]
        )
        XCTAssertFalse(routingService.desiredRunning)
        guard case .failed(.latencyStabilityLimitExceeded(let context)) =
            routingService.state else {
            return XCTFail("Expected an explicit latency stability failure")
        }
        XCTAssertNil(context.bufferFrameCount)
        XCTAssertEqual(context.estimatedApplicationLatencySeconds, 0.080)
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

    func testCommonOutputRateIsSelectedAutomaticallyAndAppliedToInput() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            supportedRates: [44_100, 48_000]
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100,
            supportedRates: [44_100, 48_000]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, output], input: input, output: output)
        )
        let service = makeService(backend: backend)

        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )

        XCTAssertEqual(route.route.nominalSampleRate, 44_100)
        XCTAssertEqual(route.route.sampleRatePlan, .synchronized(sampleRate: 44_100))
        XCTAssertEqual(backend.sampleRateWrites.count, 1)
        XCTAssertEqual(backend.sampleRateWrites[0].uid, input.id)
        XCTAssertEqual(backend.sampleRateWrites[0].rate, 44_100)
    }

    func testNoCommonRatePreservesIndependentHardwareRatesForConversion() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            supportedRates: [48_000]
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100,
            supportedRates: [16_000, 44_100]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, output], input: input, output: output)
        )
        let service = makeService(backend: backend)

        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )

        XCTAssertEqual(
            route.route.sampleRatePlan,
            .converted(inputSampleRate: 48_000, outputSampleRate: 44_100)
        )
        XCTAssertTrue(backend.sampleRateWrites.isEmpty)
        XCTAssertEqual(backend.preparedRoutes.first?.sampleRatePlan, route.route.sampleRatePlan)
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

    func testUnselectedHDMIDeviceAddAndRemovalDoNotRebuildActiveRoute() async throws {
        let input = makeDevice(uid: "input", supportsOutput: false)
        let output = makeDevice(uid: "selected-output", supportsInput: false)
        let hdmi = makeDevice(uid: "unselected-hdmi", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        let timing = ControlledCoreAudioTiming()
        let logStore = RollingLogStore()
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: CoreAudioDeviceService(
                logStore: logStore,
                backend: backend,
                timing: timing.makeTiming()
            ),
            permissionService: AudioInputPermissionSpy()
        )
        let configuration = DirectRoutingConfiguration(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: .device(uid: output.id, lastKnownName: output.name)
        )
        routingService.start(configuration: configuration)
        await routingService.waitForIdle()

        let addedSnapshot = expectation(description: "HDMI addition snapshot published")
        backend.onMakeSnapshot = addedSnapshot.fulfill
        backend.snapshot = makeSnapshot(
            devices: [input, output, hdmi],
            input: input,
            output: output
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [addedSnapshot])
        await routingService.waitForIdle()

        let removedSnapshot = expectation(description: "HDMI removal snapshot published")
        backend.onMakeSnapshot = removedSnapshot.fulfill
        backend.snapshot = makeSnapshot(
            devices: [input, output],
            input: input,
            output: output
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [removedSnapshot])
        await routingService.waitForIdle()

        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        XCTAssertFalse(
            logStore.entries.contains {
                $0.message == "Direct Routing rebuilding after hardware change"
            }
        )
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected the original route to remain active")
        }
        XCTAssertEqual(route.output.id, output.id)
    }

    func testUnrelatedHardwareInterruptionDoesNotEscalateAutomaticBuffer() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let hdmi = makeDevice(uid: "unselected-hdmi", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
            )
        )
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.004,
            maximumApplicationSeconds: 0.005,
            isLowLatency: true,
            requiresBufferEscalation: false
        )
        let inventoryTiming = ControlledCoreAudioTiming()
        let recoveryTiming = ControlledHardwareRecoveryTiming()
        let firstCheckpoint = expectation(
            description: "stability checkpoint starts recovery window"
        )
        let recoveryCheckpoint = expectation(
            description: "stability checkpoint ends recovery window"
        )
        backend.onStabilityCheckpoint = {
            switch backend.stabilityCheckpointSessionIDs.count {
            case 1:
                firstCheckpoint.fulfill()
            case 2:
                backend.routeLatencyValue = CoreAudioRouteLatency(
                    estimatedApplicationSeconds: 0.004,
                    maximumApplicationSeconds: 0.005,
                    isLowLatency: true,
                    requiresBufferEscalation: false
                )
                recoveryCheckpoint.fulfill()
            default:
                break
            }
        }
        let routingService = DirectAudioRoutingService(
            logStore: RollingLogStore(),
            deviceService: CoreAudioDeviceService(
                logStore: RollingLogStore(),
                backend: backend,
                timing: inventoryTiming.makeTiming()
            ),
            permissionService: AudioInputPermissionSpy(),
            hardwareInterruptionRecoverySleep: recoveryTiming.sleep
        )
        routingService.start(
            configuration: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )
        await routingService.waitForIdle()

        backend.snapshot = makeSnapshot(
            devices: [input, output, hdmi],
            input: input,
            output: output
        )
        backend.emitHardwareChange()
        XCTAssertEqual(
            backend.stabilityCheckpointSessionIDs.count,
            1,
            "Recovery must begin before the debounced inventory refresh"
        )
        await inventoryTiming.waitUntilSuspended()
        inventoryTiming.resume()
        await fulfillment(of: [firstCheckpoint])
        await recoveryTiming.waitUntilSuspended()

        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.008,
            maximumApplicationSeconds: 0.010,
            isLowLatency: true,
            requiresBufferEscalation: true,
            bufferEscalationReason: "transient CoreAudio interruption"
        )
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)

        recoveryTiming.resume()
        await fulfillment(of: [recoveryCheckpoint])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)

        let genuineInstabilityRebuilt = expectation(
            description: "a later genuine instability still escalates the buffer"
        )
        backend.onPrepareRoute = {
            guard backend.preparedRoutes.count == 2 else { return }
            backend.routeLatencyValue = CoreAudioRouteLatency(
                estimatedApplicationSeconds: 0.006,
                maximumApplicationSeconds: 0.009,
                isLowLatency: true,
                requiresBufferEscalation: false
            )
            genuineInstabilityRebuilt.fulfill()
        }
        backend.routeLatencyValue = CoreAudioRouteLatency(
            estimatedApplicationSeconds: 0.008,
            maximumApplicationSeconds: 0.010,
            isLowLatency: true,
            requiresBufferEscalation: true,
            bufferEscalationReason: "genuine runtime instability"
        )
        await fulfillment(of: [genuineInstabilityRebuilt], timeout: 2)
        await routingService.waitForIdle()

        XCTAssertEqual(
            backend.preparedRoutes.map(\.requestedBufferFrameSize),
            [64, 128]
        )
        try await routingService.stopAndWait()
    }

    func testHardwareInventoryChangesRemainPassiveWhileDirectRoutingIsStopped() async {
        let input = makeDevice(uid: "input", supportsOutput: false)
        let output = makeDevice(uid: "output", supportsInput: false)
        let hdmi = makeDevice(uid: "hdmi", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
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
        let snapshotRefreshed = expectation(
            description: "stopped service still publishes device inventory"
        )
        backend.onMakeSnapshot = snapshotRefreshed.fulfill
        backend.snapshot = makeSnapshot(
            devices: [input, output, hdmi],
            input: input,
            output: output
        )

        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [snapshotRefreshed])
        await routingService.waitForIdle()

        XCTAssertEqual(routingService.state, .stopped)
        XCTAssertFalse(routingService.desiredRunning)
        XCTAssertTrue(backend.preparedRoutes.isEmpty)
        XCTAssertTrue(backend.startedSessionIDs.isEmpty)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        XCTAssertTrue(backend.sampleRateWrites.isEmpty)
    }

    func testDefaultOutputChangeDoesNotRebuildAvailableExplicitOutput() async throws {
        let input = makeDevice(uid: "input", supportsOutput: false)
        let preferred = makeDevice(uid: "preferred-output", supportsInput: false)
        let speakers = makeDevice(uid: "speakers", supportsInput: false)
        let hdmi = makeDevice(uid: "hdmi", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, preferred, speakers, hdmi],
                input: input,
                output: speakers
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
        routingService.start(
            configuration: DirectRoutingConfiguration(
                inputSelection: .device(uid: input.id, lastKnownName: input.name),
                outputSelection: .device(
                    uid: preferred.id,
                    lastKnownName: preferred.name
                )
            )
        )
        await routingService.waitForIdle()

        let snapshotRefreshed = expectation(description: "new default snapshot published")
        backend.onMakeSnapshot = snapshotRefreshed.fulfill
        backend.snapshot = makeSnapshot(
            devices: [input, preferred, speakers, hdmi],
            input: input,
            output: hdmi
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await fulfillment(of: [snapshotRefreshed])
        await routingService.waitForIdle()

        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected the explicit route to remain active")
        }
        XCTAssertEqual(route.output.id, preferred.id)
        XCTAssertFalse(route.isUsingOutputFallback)
    }

    func testExplicitOutputFallbackFollowsChangedSystemDefault() async throws {
        let input = makeDevice(uid: "input", supportsOutput: false)
        let missingPreferred = makeDevice(uid: "preferred-output", supportsInput: false)
        let speakers = makeDevice(uid: "speakers", supportsInput: false)
        let hdmi = makeDevice(uid: "hdmi", supportsInput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, speakers, hdmi],
                input: input,
                output: speakers
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
        routingService.start(
            configuration: DirectRoutingConfiguration(
                inputSelection: .device(uid: input.id, lastKnownName: input.name),
                outputSelection: .device(
                    uid: missingPreferred.id,
                    lastKnownName: missingPreferred.name
                )
            )
        )
        await routingService.waitForIdle()

        let rebuilt = expectation(description: "fallback rebuilt for the new default")
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                rebuilt.fulfill()
            }
        }
        backend.snapshot = makeSnapshot(
            devices: [input, speakers, hdmi],
            input: input,
            output: hdmi
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [rebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.count, 2)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected the replacement fallback route to run")
        }
        XCTAssertEqual(route.output.id, hdmi.id)
        XCTAssertTrue(route.isUsingOutputFallback)
    }

    func testCompatibleBufferMetadataChangesDoNotRebuildConvertedRoute() async throws {
        let input = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000
        )
        let output = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, output],
                input: input,
                output: output
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
        XCTAssertEqual(backend.preparedRoutes.first?.requestedBufferFrameSize, 64)

        let changedInput = makeDevice(
            uid: "input",
            supportsOutput: false,
            sampleRate: 48_000,
            currentBufferFrameSize: 256,
            maximumBufferFrameSize: 4_096
        )
        let changedOutput = makeDevice(
            uid: "output",
            supportsInput: false,
            sampleRate: 44_100,
            currentBufferFrameSize: 256,
            maximumBufferFrameSize: 4_096
        )
        let hdmi = makeDevice(
            uid: "hdmi",
            supportsInput: false
        )
        backend.snapshot = makeSnapshot(
            devices: [changedInput, changedOutput, hdmi],
            input: changedInput,
            output: changedOutput
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()
        await routingService.waitForIdle()

        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.stoppedSessionIDs.isEmpty)
        guard case .running = routingService.state else {
            return XCTFail("Expected the original route to remain active")
        }
    }

    func testActiveNominalSampleRateChangeStillTriggersFullRouteRebuild() async throws {
        let original = makeDevice(
            uid: "duplex",
            sampleRate: 48_000,
            supportedRates: [44_100, 48_000]
        )
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [original],
                input: original,
                output: original
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

        let rebuilt = expectation(
            description: "route rebuilt after active nominal sample-rate change"
        )
        backend.onPrepareRoute = {
            if backend.preparedRoutes.count == 2 {
                rebuilt.fulfill()
            }
        }
        let changedRate = makeDevice(
            uid: "duplex",
            sampleRate: 44_100,
            supportedRates: [44_100, 48_000]
        )
        backend.simulateExternalNominalSampleRateChange(
            44_100,
            for: changedRate.id
        )
        backend.snapshot = makeSnapshot(
            devices: [changedRate],
            input: changedRate,
            output: changedRate
        )
        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [rebuilt])
        await routingService.waitForIdle()
        XCTAssertEqual(backend.preparedRoutes.count, 2)
        XCTAssertEqual(backend.stoppedSessionIDs.count, 1)
        guard case .running(let route) = routingService.state else {
            return XCTFail("Expected the rebuilt route to be running")
        }
        XCTAssertEqual(route.nominalSampleRate, 44_100)
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

    func testListenerRebuildFailureDoesNotBlockNewDefaultSnapshotPublication() async {
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
        let snapshotPublished = expectation(
            description: "new snapshot is published before listener reconciliation"
        )
        deviceService.onHardwareChanged = snapshotPublished.fulfill
        backend.rebuildListenersErrors = [
            CoreAudioBackendFailure(
                operation: "Injected listener removal",
                status: kAudioHardwareUnspecifiedError
            ),
        ]
        backend.snapshot = makeSnapshot(
            devices: [input, speakers],
            input: input,
            output: speakers
        )

        backend.emitHardwareChange()
        await timing.waitUntilSuspended()
        timing.resume()

        await fulfillment(of: [snapshotPublished])
        XCTAssertEqual(deviceService.snapshot.defaultOutputUID, speakers.id)
        XCTAssertEqual(deviceService.snapshot.outputDevices.map(\.id), [speakers.id])
        XCTAssertGreaterThan(deviceService.snapshot.revision, 1)
        XCTAssertEqual(backend.rebuildListenersCount, 1)
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
        inputChannelCount: Int = 2,
        currentBufferFrameSize: UInt32 = 512,
        minimumBufferFrameSize: UInt32 = 64,
        maximumBufferFrameSize: UInt32 = 2_048,
        inputPhysicalStreamFormats: [AudioHardwareStreamFormat] = [],
        outputPhysicalStreamFormats: [AudioHardwareStreamFormat] = []
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
            currentBufferFrameSize: currentBufferFrameSize,
            supportedBufferFrameSizeRange: AudioBufferFrameSizeRange(
                minimum: minimumBufferFrameSize,
                maximum: maximumBufferFrameSize
            ),
            inputPhysicalStreamFormats: inputPhysicalStreamFormats,
            outputPhysicalStreamFormats: outputPhysicalStreamFormats
        )
    }

    private func makePhysicalFormat(
        sampleRate: Double
    ) -> AudioHardwareStreamFormat {
        AudioHardwareStreamFormat(
            sampleRate: sampleRate,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsSignedInteger,
            bitsPerChannel: 16,
            bytesPerFrame: 4,
            framesPerPacket: 1,
            bytesPerPacket: 4
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
        let sampleRatePlan: AudioSampleRatePlan
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
    private(set) var stabilityCheckpointSessionIDs: [UUID] = []
    private(set) var shutdownCount = 0
    private(set) var rebuildListenersCount = 0
    private(set) var lastPreparedSessionID: UUID?
    var snapshotAfterPrepare: AudioHardwareSnapshot?
    var appliesSampleRateWritesImmediately = true
    var onPrepareRoute: (() -> Void)?
    var onStopRoute: (() -> Void)?
    var onStabilityCheckpoint: (() -> Void)?
    var onMakeSnapshot: (() -> Void)?
    var cleanupFailureBatches: [[String]] = []
    var unreleasedResourceFailures: [String] = []
    var startError: Error?
    var prepareRouteErrors: [Error] = []
    var rebuildListenersErrors: [Error] = []
    var routeLatencyValue: CoreAudioRouteLatency?
    var routeLatencyProvider: ((UUID) -> CoreAudioRouteLatency?)?
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
        if !rebuildListenersErrors.isEmpty {
            throw rebuildListenersErrors.removeFirst()
        }
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
                    supportedBufferFrameSizeRange: descriptor.supportedBufferFrameSizeRange,
                    inputPhysicalStreamFormats:
                        descriptor.inputPhysicalStreamFormats,
                    outputPhysicalStreamFormats:
                        descriptor.outputPhysicalStreamFormats
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

    func simulateExternalNominalSampleRateChange(
        _ rate: Double,
        for uid: AudioDeviceUID
    ) {
        rates[uid] = rate
    }

    func isAlive(uid: AudioDeviceUID) throws -> Bool {
        snapshot.devices.first { $0.id == uid }?.isAlive ?? false
    }

    func prepareRoute(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        sampleRatePlan: AudioSampleRatePlan,
        requestedBufferFrameSize: UInt32?,
        validateOwnership: () throws -> Void
    ) throws -> UUID {
        try validateOwnership()
        preparedRoutes.append(
            PreparedRouteCall(
                input: input,
                output: output,
                sampleRatePlan: sampleRatePlan,
                requestedBufferFrameSize: requestedBufferFrameSize
            )
        )
        if !prepareRouteErrors.isEmpty {
            throw prepareRouteErrors.removeFirst()
        }
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

    func routeLatency(sessionID: UUID) -> CoreAudioRouteLatency? {
        routeLatencyProvider?(sessionID) ?? routeLatencyValue
    }

    func checkpointRouteStability(sessionID: UUID) {
        stabilityCheckpointSessionIDs.append(sessionID)
        onStabilityCheckpoint?()
    }

    func stopAndDestroyRoute(sessionID: UUID) -> [String] {
        stoppedSessionIDs.append(sessionID)
        onStopRoute?()
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

@MainActor
private final class ControlledHardwareRecoveryTiming {
    private var continuation: CheckedContinuation<Void, Error>?
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ nanoseconds: UInt64) async throws {
        XCTAssertEqual(nanoseconds, 2_000_000_000)
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let waiters = suspendedWaiters
            suspendedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
