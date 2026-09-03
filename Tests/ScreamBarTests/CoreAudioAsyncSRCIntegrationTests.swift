@testable import ScreamBar
import Combine
import XCTest

private struct ConvertedRouteSoakIdentity: Equatable {
    let inputUID: AudioDeviceUID
    let outputUID: AudioDeviceUID
    let sampleRatePlan: AudioSampleRatePlan
    let bufferFrameSize: UInt32?

    init(route: EffectiveAudioRoute) {
        inputUID = route.input.id
        outputUID = route.output.id
        sampleRatePlan = route.sampleRatePlan
        bufferFrameSize = route.bufferFrameSize
    }
}

private final class ConvertedRouteSoakObservation {
    private let expectedIdentity: ConvertedRouteSoakIdentity
    private(set) var violations: [String] = []

    init(expectedRoute: EffectiveAudioRoute) {
        expectedIdentity = ConvertedRouteSoakIdentity(route: expectedRoute)
    }

    func observe(_ state: AudioRoutingState) {
        switch state {
        case .running(let route):
            let identity = ConvertedRouteSoakIdentity(route: route)
            if identity != expectedIdentity {
                violations.append(
                    "Converted route identity changed during soak: \(identity)"
                )
            }
        case .starting:
            violations.append("Direct Routing restarted during soak")
        case .reconfiguring:
            violations.append(
                "Direct Routing reconfigured after a disruption during soak"
            )
        case .stopped:
            violations.append("Direct Routing stopped during soak")
        case .waitingForInput:
            violations.append("Direct Routing lost its input during soak")
        case .waitingForOutput:
            violations.append("Direct Routing lost its output during soak")
        case .stopping:
            violations.append("Direct Routing began stopping during soak")
        case .failed(let error):
            violations.append(
                "Direct Routing failed during soak: \(error.localizedDescription)"
            )
        }
    }
}

@MainActor
final class CoreAudioAsyncSRCIntegrationTests: XCTestCase {
    private static let integrationEnvironmentKey =
        "SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS"
    private static let soakDurationEnvironmentKey =
        "SCREAMBAR_ASYNC_SRC_SOAK_SECONDS"
    private static let inputNameEnvironmentKey =
        "SCREAMBAR_ASYNC_SRC_INPUT_NAME"
    private static let outputNameEnvironmentKey =
        "SCREAMBAR_ASYNC_SRC_OUTPUT_NAME"
    private static let defaultInputName = "Cubilux SPDIF Receiver"
    private static let defaultOutputName = "Bose QC 45"
    private static let defaultSmokeDurationSeconds = 1.0

    func testSoakObservationRetainsDisruptionAfterRouteIsRebuilt() {
        let initialRoute = makeObservationRoute(bufferFrameSize: 64)
        let observation = ConvertedRouteSoakObservation(
            expectedRoute: initialRoute
        )

        observation.observe(.running(initialRoute))
        observation.observe(.reconfiguring)
        observation.observe(
            .running(makeObservationRoute(bufferFrameSize: 128))
        )

        XCTAssertEqual(observation.violations.count, 2)
        XCTAssertTrue(
            observation.violations.contains {
                $0.contains("reconfigured after a disruption")
            }
        )
        XCTAssertTrue(
            observation.violations.contains {
                $0.contains("route identity changed")
            }
        )
    }

    func testIncompatibleHardwareRatesUseStableAutomaticConversion() async throws {
        try requireHardwareIntegrationTests()
        let backend = LegacyCoreAudioBackend()
        let initialSnapshot = try backend.makeSnapshot(revision: 1)
        let input = try findDevice(
            in: initialSnapshot.inputDevices,
            environmentKey: Self.inputNameEnvironmentKey,
            defaultName: Self.defaultInputName
        )
        let output = try findDevice(
            in: initialSnapshot.outputDevices,
            environmentKey: Self.outputNameEnvironmentKey,
            defaultName: Self.defaultOutputName
        )
        let service = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend
        )
        var activeSessionID: UUID?
        defer {
            if let activeSessionID {
                do {
                    try service.stopAndDestroyRoute(sessionID: activeSessionID)
                } catch {
                    XCTFail("Converted route cleanup failed: \(error)")
                }
            }
            service.shutdown()
        }

        let preparedRoute = try await service.prepareRoute(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: .device(uid: output.id, lastKnownName: output.name)
        )
        activeSessionID = preparedRoute.sessionID
        guard case let .converted(inputSampleRate, outputSampleRate) =
            preparedRoute.route.sampleRatePlan else {
            throw XCTSkip(
                "Selected devices now expose a common nominal sample rate"
            )
        }
        XCTAssertEqual(inputSampleRate, input.currentNominalSampleRate)
        XCTAssertEqual(outputSampleRate, output.currentNominalSampleRate)
        let converterLatencySeconds = try XCTUnwrap(
            backend.asyncSRCConverterLatency(sessionID: preparedRoute.sessionID)
        )
        XCTAssertLessThanOrEqual(converterLatencySeconds, 0.001)

        try service.startRoute(preparedRoute)
        let durationNanoseconds = UInt64(
            Self.defaultSmokeDurationSeconds * 1_000_000_000
        )
        let pollIntervalNanoseconds: UInt64 = 1_000_000_000
        var elapsedNanoseconds: UInt64 = 0
        while elapsedNanoseconds < durationNanoseconds {
            let remainingNanoseconds = durationNanoseconds - elapsedNanoseconds
            let sleepNanoseconds = min(pollIntervalNanoseconds, remainingNanoseconds)
            try await Task.sleep(nanoseconds: sleepNanoseconds)
            elapsedNanoseconds += sleepNanoseconds
            let currentMetrics = try XCTUnwrap(
                backend.asyncSRCMetrics(sessionID: preparedRoute.sessionID)
            )
            guard assertHealthy(
                currentMetrics,
                inputSampleRate: inputSampleRate,
                outputSampleRate: outputSampleRate,
                expectedBufferFrameSize: preparedRoute.route.bufferFrameSize
            ) else { return }
        }

        let metrics = try XCTUnwrap(
            backend.asyncSRCMetrics(sessionID: preparedRoute.sessionID)
        )
        XCTAssertGreaterThan(metrics.capturedFrames, 0)
        XCTAssertGreaterThan(metrics.renderedFrames, 0)

        try service.stopAndDestroyRoute(sessionID: preparedRoute.sessionID)
        activeSessionID = nil
        XCTAssertNoThrow(try service.confirmRouteResourcesReleased())
    }

    func testDirectRoutingServiceSoakKeepsConvertedRouteHealthyAndTearsDown() async throws {
        try requireHardwareIntegrationTests()
        let backend = LegacyCoreAudioBackend()
        let initialSnapshot = try backend.makeSnapshot(revision: 1)
        let input = try findDevice(
            in: initialSnapshot.inputDevices,
            environmentKey: Self.inputNameEnvironmentKey,
            defaultName: Self.defaultInputName
        )
        let output = try findDevice(
            in: initialSnapshot.outputDevices,
            environmentKey: Self.outputNameEnvironmentKey,
            defaultName: Self.defaultOutputName
        )
        let logStore = RollingLogStore()
        let deviceService = CoreAudioDeviceService(
            logStore: logStore,
            backend: backend
        )
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: deviceService,
            permissionService: IntegrationAudioInputPermissionSpy()
        )
        defer {
            let failures = deviceService.shutdown()
            XCTAssertTrue(
                failures.isEmpty,
                "Hardware integration cleanup failed: \(failures)"
            )
        }

        routingService.start(
            configuration: DirectRoutingConfiguration(
                inputSelection: .device(
                    uid: input.id,
                    lastKnownName: input.name
                ),
                outputSelection: .device(
                    uid: output.id,
                    lastKnownName: output.name
                ),
                bufferSize: .automatic
            )
        )
        await routingService.waitForIdle()
        try assertRunningConvertedRoute(routingService.state)

        guard case .running(let initiallyRunningRoute) = routingService.state else {
            XCTFail("Expected an initially running converted route")
            return
        }
        let soakObservation = ConvertedRouteSoakObservation(
            expectedRoute: initiallyRunningRoute
        )
        let stateObservation = routingService.$state.sink {
            soakObservation.observe($0)
        }

        let deadline = Date().addingTimeInterval(soakDurationSeconds())
        var runningObservationCount = 0
        repeat {
            try await Task.sleep(nanoseconds: 500_000_000)
            await routingService.waitForIdle()
            guard soakObservation.violations.isEmpty else {
                let routingLog = logStore.entries
                    .filter { $0.source == .routing }
                    .map(\.message)
                    .joined(separator: " | ")
                XCTFail(
                    soakObservation.violations.joined(separator: "; ")
                        + "; routing log: " + routingLog
                )
                stateObservation.cancel()
                return
            }
            switch routingService.state {
            case .running:
                try assertRunningConvertedRoute(routingService.state)
                runningObservationCount += 1
            case .starting, .reconfiguring:
                XCTFail("Direct Routing changed sessions during soak")
                stateObservation.cancel()
                return
            case .failed(let error):
                XCTFail("Direct Routing failed during soak: \(error.localizedDescription)")
                return
            default:
                XCTFail("Direct Routing unexpectedly stopped during soak")
                return
            }
        } while Date() < deadline
        XCTAssertGreaterThan(runningObservationCount, 0)

        // The service monitor polls every 500 ms. Keep observing through one
        // additional monitor window so a disruption at the soak deadline
        // cannot be hidden by immediately cancelling the monitor during stop.
        try await Task.sleep(nanoseconds: 600_000_000)
        await routingService.waitForIdle()
        switch routingService.state {
        case .running:
            try assertRunningConvertedRoute(routingService.state)
        default:
            XCTFail(
                "Direct Routing was not running after the final monitor window: \(routingService.state)"
            )
        }
        XCTAssertTrue(
            soakObservation.violations.isEmpty,
            soakObservation.violations.joined(separator: "; ")
        )
        stateObservation.cancel()

        try await routingService.stopAndWait()
        XCTAssertEqual(routingService.state, .stopped)
        XCTAssertNoThrow(try deviceService.confirmRouteResourcesReleased())
    }

    private func requireHardwareIntegrationTests() throws {
        guard ProcessInfo.processInfo.environment[Self.integrationEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.integrationEnvironmentKey)=1 after granting audio-input permission"
            )
        }
    }

    private func findDevice(
        in devices: [AudioDeviceDescriptor],
        environmentKey: String,
        defaultName: String
    ) throws -> AudioDeviceDescriptor {
        let requestedName = ProcessInfo.processInfo.environment[environmentKey]
            ?? defaultName
        guard let device = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains(requestedName)
        }) else {
            throw XCTSkip(
                "CoreAudio device matching '\(requestedName)' is unavailable"
            )
        }
        return device
    }

    private func soakDurationSeconds() -> Double {
        guard let rawDuration = ProcessInfo.processInfo.environment[
            Self.soakDurationEnvironmentKey
        ], let duration = Double(rawDuration), duration > 0 else {
            return Self.defaultSmokeDurationSeconds
        }
        return duration
    }

    private func assertHealthy(
        _ metrics: AsyncSRCMetrics,
        inputSampleRate: Double,
        outputSampleRate: Double,
        expectedBufferFrameSize: UInt32?
    ) -> Bool {
        let callbackFramesMatchConfiguration = expectedBufferFrameSize.map {
            metrics.maximumInputCallbackFrames <= $0
                && metrics.maximumOutputCallbackFrames <= $0
        } ?? true
        guard !metrics.hasRuntimeErrors,
              metrics.underrunCount == 0,
              metrics.latencyCeilingUnderrunCount == 0,
              metrics.overflowCount == 0,
              metrics.resynchronizationCount == 0,
              metrics.droppedInputFrames == 0,
              metrics.readableFrames < metrics.ringCapacityFrames,
              callbackFramesMatchConfiguration,
              !AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                  executionNanoseconds:
                    metrics.maximumInputCallbackExecutionNanoseconds,
                  frameCount: metrics.maximumInputCallbackFrames,
                  sampleRate: inputSampleRate
              ),
              !AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                  executionNanoseconds:
                    metrics.maximumOutputCallbackExecutionNanoseconds,
                  frameCount: metrics.maximumOutputCallbackFrames,
                  sampleRate: outputSampleRate
              ),
              metrics.playbackRate.isFinite,
              metrics.playbackRate > 0.95,
              metrics.playbackRate < 1.05,
              metrics.maximumPlaybackRateDeviation
                <= AsyncSRCClockControlPolicy.maximumPlaybackRateDeviation
                    + 0.000_001 else {
            XCTFail("Unhealthy asynchronous SRC metrics: \(metrics)")
            return false
        }
        return true
    }

    private func assertRunningConvertedRoute(
        _ state: AudioRoutingState
    ) throws {
        guard case .running(let route) = state else {
            XCTFail("Expected Direct Routing to be running, got \(state)")
            return
        }
        guard route.usesSampleRateConversion else {
            throw XCTSkip("Selected devices now expose a common nominal sample rate")
        }
        XCTAssertTrue(
            route.bufferFrameSize.map {
                AsyncSRCLowLatencyPolicy.preferredBufferFrameSizes.contains($0)
            } ?? true
        )
        let latencySeconds = try XCTUnwrap(
            route.estimatedApplicationLatencySeconds
        )
        XCTAssertGreaterThan(latencySeconds, 0)
        if route.isLowLatency {
            XCTAssertLessThanOrEqual(
                latencySeconds,
                AsyncSRCBufferSizing.maximumApplicationLatencySeconds
            )
        }
    }

    private func makeObservationRoute(
        bufferFrameSize: UInt32
    ) -> EffectiveAudioRoute {
        let input = AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: "observation-input"),
            name: "Observation Input",
            inputChannelCount: 2,
            outputChannelCount: 0,
            isAlive: true,
            currentNominalSampleRate: 48_000,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 48_000, maximum: 48_000),
            ],
            currentBufferFrameSize: bufferFrameSize
        )
        let output = AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: "observation-output"),
            name: "Observation Output",
            inputChannelCount: 0,
            outputChannelCount: 2,
            isAlive: true,
            currentNominalSampleRate: 44_100,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 44_100, maximum: 44_100),
            ],
            currentBufferFrameSize: bufferFrameSize
        )
        return EffectiveAudioRoute(
            input: input,
            output: output,
            sampleRatePlan: .converted(
                inputSampleRate: 48_000,
                outputSampleRate: 44_100
            ),
            isUsingOutputFallback: false,
            bufferFrameSize: bufferFrameSize
        )
    }
}

@MainActor
private final class IntegrationAudioInputPermissionSpy:
    AudioInputPermissionServicing {
    func requestPermissionIfNeeded() async throws {}
}
