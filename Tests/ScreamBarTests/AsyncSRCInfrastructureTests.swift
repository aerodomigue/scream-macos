@testable import ScreamBar
import AudioToolbox
import Darwin
import ScreamBarCoreAudioRT
import XCTest

private let deadlineTestDelayMicroseconds: useconds_t = 2_000

private final class AsyncSRCTestInputRenderer {
    var delayMicroseconds: useconds_t = 0
}

private func asyncSRCTestInputRenderCallback(
    _ referenceContext: UnsafeMutableRawPointer?,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ outputData: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    _ = actionFlags
    _ = timestamp
    _ = busNumber
    _ = frameCount
    _ = outputData
    guard let referenceContext else { return kAudio_ParamError }
    let renderer = Unmanaged<AsyncSRCTestInputRenderer>
        .fromOpaque(referenceContext)
        .takeUnretainedValue()
    if renderer.delayMicroseconds > 0 {
        usleep(renderer.delayMicroseconds)
    }
    return noErr
}

final class AsyncSRCInfrastructureTests: XCTestCase {
    private struct TimingScenario {
        let inputSampleRate: Double
        let outputSampleRate: Double
    }

    private static let timingSoakEnvironmentKey =
        "SCREAMBAR_ASYNC_SRC_TIMING_SOAK_SECONDS"
    private static let simulatedDurationSeconds = 60.0
    private static let maximumTimingJitterSeconds = 0.000_1
    private static let maximumClockDriftPartsPerMillion = 250.0
    private static let maximumSupportedClockDriftPartsPerMillion = 1_000.0
    private static let clockDriftTestMagnitudesPartsPerMillion = [
        100.0,
        250.0,
        maximumSupportedClockDriftPartsPerMillion,
    ]
    private static let timingScenarios = [
        TimingScenario(inputSampleRate: 32_000, outputSampleRate: 44_100),
        TimingScenario(inputSampleRate: 44_100, outputSampleRate: 48_000),
        TimingScenario(inputSampleRate: 48_000, outputSampleRate: 44_100),
        TimingScenario(inputSampleRate: 48_000, outputSampleRate: 96_000),
        TimingScenario(inputSampleRate: 96_000, outputSampleRate: 44_100),
        TimingScenario(inputSampleRate: 192_000, outputSampleRate: 48_000),
    ]

    func testEmptyCallbackTelemetryHasDeterministicBaseline() throws {
        let placeholderAudioUnit = try XCTUnwrap(AudioUnit(bitPattern: 1))
        let context = try XCTUnwrap(
            ScreamBarAsyncSRCContextCreate(
                placeholderAudioUnit,
                placeholderAudioUnit,
                1,
                1,
                128,
                128,
                1_024,
                256,
                480,
                608,
                48_000,
                44_100,
                true,
                true
            )
        )
        defer { ScreamBarAsyncSRCContextDestroy(context) }

        var rawMetrics = ScreamBarAsyncSRCMetrics()
        ScreamBarAsyncSRCCopyMetrics(context, &rawMetrics)
        let metrics = AsyncSRCMetrics(rawMetrics)

        XCTAssertEqual(metrics.fifoFillSampleCount, 0)
        XCTAssertEqual(metrics.fifoFillFrameSum, 0)
        XCTAssertEqual(metrics.minimumFIFOFillFrames, 0)
        XCTAssertEqual(metrics.maximumFIFOFillFrames, 0)
        XCTAssertEqual(metrics.meanFIFOFillFrames, 0)
        XCTAssertEqual(metrics.playbackRateAdjustmentCount, 0)
        XCTAssertEqual(metrics.playbackRate, 1)
        XCTAssertNil(metrics.minimumPlaybackRate)
        XCTAssertNil(metrics.maximumPlaybackRate)
        XCTAssertFalse(metrics.telemetrySaturated)
    }

    func testRingBufferRejectsInvalidCapacity() {
        XCTAssertNil(ScreamBarSPSCRingBufferCreate(2, 0))
        XCTAssertNil(ScreamBarSPSCRingBufferCreate(2, 3))
        XCTAssertNil(ScreamBarSPSCRingBufferCreate(0, 4))
    }

    func testRingBufferPreservesWrappedInterleavedFrames() throws {
        let ringBuffer = try XCTUnwrap(ScreamBarSPSCRingBufferCreate(2, 4))
        defer { ScreamBarSPSCRingBufferDestroy(ringBuffer) }
        let firstInput: [Float32] = [1, 2, 3, 4, 5, 6]
        let secondInput: [Float32] = [7, 8, 9, 10, 11, 12]
        var firstOutput = [Float32](repeating: 0, count: 4)
        var finalOutput = [Float32](repeating: 0, count: 8)

        XCTAssertEqual(
            firstInput.withUnsafeBufferPointer {
                ScreamBarSPSCRingBufferWriteMappedInterleaved(
                    ringBuffer,
                    $0.baseAddress!,
                    2,
                    3
                )
            },
            3
        )
        XCTAssertEqual(
            firstOutput.withUnsafeMutableBufferPointer {
                ScreamBarSPSCRingBufferReadInterleaved(ringBuffer, $0.baseAddress!, 2)
            },
            2
        )
        XCTAssertEqual(firstOutput, [1, 2, 3, 4])
        XCTAssertEqual(
            secondInput.withUnsafeBufferPointer {
                ScreamBarSPSCRingBufferWriteMappedInterleaved(
                    ringBuffer,
                    $0.baseAddress!,
                    2,
                    3
                )
            },
            3
        )
        XCTAssertEqual(
            finalOutput.withUnsafeMutableBufferPointer {
                ScreamBarSPSCRingBufferReadInterleaved(ringBuffer, $0.baseAddress!, 4)
            },
            4
        )
        XCTAssertEqual(finalOutput, [5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(ScreamBarSPSCRingBufferReadableFrames(ringBuffer), 0)
        XCTAssertEqual(ScreamBarSPSCRingBufferWritableFrames(ringBuffer), 4)
    }

    func testRingBufferDuplicatesMonoAndSilencesUnmappedChannels() throws {
        let ringBuffer = try XCTUnwrap(ScreamBarSPSCRingBufferCreate(3, 4))
        defer { ScreamBarSPSCRingBufferDestroy(ringBuffer) }
        let input: [Float32] = [0.25, -0.5]
        var output = [Float32](repeating: 1, count: 6)

        XCTAssertEqual(
            input.withUnsafeBufferPointer {
                ScreamBarSPSCRingBufferWriteMappedInterleaved(
                    ringBuffer,
                    $0.baseAddress!,
                    1,
                    2
                )
            },
            2
        )
        XCTAssertEqual(
            output.withUnsafeMutableBufferPointer {
                ScreamBarSPSCRingBufferReadInterleaved(ringBuffer, $0.baseAddress!, 2)
            },
            2
        )
        XCTAssertEqual(output, [0.25, 0.25, 0, -0.5, -0.5, 0])
    }

    func testClockControllerUsesOutputClockAndCorrectsFillDirection() throws {
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }

        let centeredRate = ScreamBarAsyncSRCClockControllerUpdate(
            controller,
            512,
            512,
            128,
            44_100,
            44_100,
            true
        )
        let highFillRate = ScreamBarAsyncSRCClockControllerUpdate(
            controller,
            768,
            512,
            128,
            44_100,
            44_100,
            true
        )
        ScreamBarAsyncSRCClockControllerReset(controller)
        let lowFillRate = ScreamBarAsyncSRCClockControllerUpdate(
            controller,
            256,
            512,
            128,
            44_100,
            44_100,
            true
        )

        XCTAssertEqual(centeredRate, 1, accuracy: 0.000_001)
        XCTAssertGreaterThan(highFillRate, 1)
        XCTAssertLessThan(lowFillRate, 1)
    }

    func testAdaptiveClockPolicyUsesConfiguredQuantaNotLatencyClassification() {
        let fallbackConfiguration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 128,
            outputBufferFrames: 128,
            inputSampleRate: 44_100,
            outputSampleRate: 48_000
        )

        XCTAssertFalse(fallbackConfiguration.isLowLatency)
        XCTAssertTrue(
            AsyncSRCClockControlPolicy.usesAdaptiveControl(
                inputBufferFrames: 128,
                outputBufferFrames: 128
            )
        )
        XCTAssertFalse(
            AsyncSRCClockControlPolicy.usesAdaptiveControl(
                inputBufferFrames: 256,
                outputBufferFrames: 128
            )
        )
        XCTAssertFalse(
            AsyncSRCClockControlPolicy.usesAdaptiveControl(
                inputBufferFrames: 128,
                outputBufferFrames: 256
            )
        )
        XCTAssertFalse(
            AsyncSRCClockControlPolicy.usesAdaptiveControl(
                inputBufferFrames: nil,
                outputBufferFrames: 128
            )
        )
    }

    func testClockControllerRecoversAfterCrossingTarget() throws {
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }

        for _ in 0..<10_000 {
            _ = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                2_048,
                1_024,
                512,
                44_100,
                44_100,
                false
            )
        }
        var recoveryRate = 1.0
        for _ in 0..<5_000 {
            recoveryRate = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                512,
                1_024,
                512,
                44_100,
                44_100,
                false
            )
        }

        XCTAssertLessThan(recoveryRate, 1)
    }

    func testClockControllerKeepsLongRunningDriftSimulationBounded() throws {
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }
        let inputSampleRate = 48_000.0
        let outputSampleRate = 44_100.0
        let outputFrames: UInt32 = 128
        let targetFill = 1_024.0
        let inputClockScalar = 1.000_1
        let outputClockScalar = 1.0
        let callbackCount = Int(10 * 60 * outputSampleRate / Double(outputFrames))
        var fill = targetFill

        for _ in 0..<callbackCount {
            let playbackRate = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                UInt32(fill.rounded()),
                UInt32(targetFill),
                outputFrames,
                inputSampleRate,
                outputSampleRate,
                false
            )
            let nominalInputFrames = Double(outputFrames)
                * inputSampleRate / outputSampleRate
            fill += nominalInputFrames * outputClockScalar / inputClockScalar
                - nominalInputFrames * playbackRate
        }

        XCTAssertEqual(fill, targetFill, accuracy: 32)
    }

    func testAdaptiveCallbackMatrixDuringRequestedSoak() throws {
        let deadline = Date().addingTimeInterval(requestedTimingSoakDuration())
        repeat {
            for scenario in Self.timingScenarios {
                for frameCount: UInt32 in [64, 128] {
                    for driftPartsPerMillion in [
                        -Self.maximumClockDriftPartsPerMillion,
                        Self.maximumClockDriftPartsPerMillion,
                    ] {
                        for jitterSeconds in [0.0, Self.maximumTimingJitterSeconds] {
                            try assertStableTiming(
                                inputSampleRate: scenario.inputSampleRate,
                                outputSampleRate: scenario.outputSampleRate,
                                frameCount: frameCount,
                                inputDriftPartsPerMillion: driftPartsPerMillion,
                                maximumJitterSeconds: jitterSeconds
                            )
                        }
                    }
                }
            }
        } while Date() < deadline
    }

    func testAdaptiveControllerHandlesWideDriftWithJitterAndBursts() throws {
        let scenarios = [
            TimingScenario(inputSampleRate: 44_100, outputSampleRate: 48_000),
            TimingScenario(inputSampleRate: 48_000, outputSampleRate: 44_100),
        ]
        for scenario in scenarios {
            for frameCount: UInt32 in [64, 128] {
                for driftMagnitude in
                    Self.clockDriftTestMagnitudesPartsPerMillion {
                    for driftSign in [-1.0, 1.0] {
                        let driftPartsPerMillion = driftMagnitude * driftSign
                        let finalPlaybackRate = try assertStableTiming(
                            inputSampleRate: scenario.inputSampleRate,
                            outputSampleRate: scenario.outputSampleRate,
                            frameCount: frameCount,
                            inputDriftPartsPerMillion: driftPartsPerMillion,
                            maximumJitterSeconds:
                                Self.maximumTimingJitterSeconds,
                            includesInputBursts: true
                        )
                        XCTAssertEqual(
                            finalPlaybackRate,
                            1 + driftPartsPerMillion / 1_000_000,
                            accuracy: 0.000_15,
                            "Controller did not settle for \(Int(scenario.inputSampleRate)) → \(Int(scenario.outputSampleRate)) Hz, \(frameCount) frames, \(driftPartsPerMillion) ppm"
                        )
                        XCTAssertLessThanOrEqual(
                            abs(finalPlaybackRate - 1),
                            0.001_5,
                            "Controller exceeded its ±1,500 ppm authority"
                        )
                    }
                }
            }
        }
    }

    func testLowLatencyControllerReacquiresAfterClockDriftReverses() throws {
        let inputSampleRate = 48_000.0
        let outputSampleRate = 44_100.0
        let frameCount: UInt32 = 64
        let reversalTimeSeconds = 45.0
        let totalDurationSeconds = 90.0
        let rateMeasurementSeconds = 5.0
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: frameCount,
            outputBufferFrames: frameCount,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        XCTAssertTrue(configuration.isLowLatency)
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }

        let outputPeriod = Double(frameCount) / outputSampleRate
        let controllerTargetFillFrames = configuration.maximumTargetFillFrames
        let primingThreshold = controllerTargetFillFrames
            + min(
                frameCount / 2,
                configuration.maximumTargetFillFrames
                    - controllerTargetFillFrames
            )
        var readableFrames = Double(
            ((primingThreshold + frameCount - 1) / frameCount) * frameCount
        )
        var inputCallbackIndex = 1
        var outputCallbackIndex = 0
        var nextNominalInputTime = inputPeriod(
            frameCount: frameCount,
            sampleRate: inputSampleRate,
            driftPartsPerMillion:
                Self.maximumSupportedClockDriftPartsPerMillion
        )
        var outputTime = 0.0
        var positiveDriftRates: [Double] = []
        var reversedDriftRates: [Double] = []

        while outputTime < totalDurationSeconds {
            let currentDrift = outputTime < reversalTimeSeconds
                ? Self.maximumSupportedClockDriftPartsPerMillion
                : -Self.maximumSupportedClockDriftPartsPerMillion
            let currentInputPeriod = inputPeriod(
                frameCount: frameCount,
                sampleRate: inputSampleRate,
                driftPartsPerMillion: currentDrift
            )
            let nextInputTime = nextNominalInputTime
                + deterministicInputTimingOffset(
                    index: inputCallbackIndex,
                    inputPeriod: currentInputPeriod,
                    maximumJitterSeconds: Self.maximumTimingJitterSeconds,
                    includesBursts: true
                )
            if nextInputTime <= outputTime {
                repeat {
                    readableFrames += Double(frameCount)
                    XCTAssertLessThanOrEqual(
                        readableFrames,
                        Double(configuration.ringCapacityFrames)
                    )
                    inputCallbackIndex += 1
                    nextNominalInputTime += currentInputPeriod
                } while nextNominalInputTime
                    + deterministicInputTimingOffset(
                        index: inputCallbackIndex,
                        inputPeriod: currentInputPeriod,
                        maximumJitterSeconds: Self.maximumTimingJitterSeconds,
                        includesBursts: true
                    ) <= outputTime
            }

            let playbackRate = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                UInt32(max(0, readableFrames.rounded())),
                controllerTargetFillFrames,
                frameCount,
                inputSampleRate,
                outputSampleRate,
                true
            )
            let consumedFrames = Double(frameCount)
                * inputSampleRate / outputSampleRate * playbackRate
            guard readableFrames >= consumedFrames else {
                XCTFail(
                    "Modeled underrun after drift reversal at \(outputTime) seconds"
                )
                return
            }
            readableFrames -= consumedFrames
            if outputTime >= reversalTimeSeconds - rateMeasurementSeconds,
               outputTime < reversalTimeSeconds {
                positiveDriftRates.append(playbackRate)
            } else if outputTime
                        >= totalDurationSeconds - rateMeasurementSeconds {
                reversedDriftRates.append(playbackRate)
            }
            outputCallbackIndex += 1
            outputTime = Double(outputCallbackIndex) * outputPeriod
                + deterministicJitter(
                    index: outputCallbackIndex,
                    phase: 1.91,
                    amplitudeSeconds: Self.maximumTimingJitterSeconds
                )
        }

        XCTAssertFalse(positiveDriftRates.isEmpty)
        XCTAssertFalse(reversedDriftRates.isEmpty)
        let positiveDriftMean = positiveDriftRates.reduce(0, +)
            / Double(positiveDriftRates.count)
        let reversedDriftMean = reversedDriftRates.reduce(0, +)
            / Double(reversedDriftRates.count)
        XCTAssertGreaterThan(positiveDriftMean, 1)
        XCTAssertLessThan(reversedDriftMean, 1)
        XCTAssertEqual(
            positiveDriftMean,
            1 + Self.maximumSupportedClockDriftPartsPerMillion / 1_000_000,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            reversedDriftMean,
            1 - Self.maximumSupportedClockDriftPartsPerMillion / 1_000_000,
            accuracy: 0.000_15
        )
    }

    func testLatencyClassificationMatrixEnforcesFiveMillisecondGoalAndTenMillisecondCeiling() {
        var encounteredFallback = false
        for scenario in Self.timingScenarios {
            for frameCount: UInt32 in [64, 128] {
                let configuration = AsyncSRCBufferSizing.configuration(
                    inputBufferFrames: frameCount,
                    outputBufferFrames: frameCount,
                    inputSampleRate: scenario.inputSampleRate,
                    outputSampleRate: scenario.outputSampleRate
                )
                let routeDescription = "\(Int(scenario.inputSampleRate)) → "
                    + "\(Int(scenario.outputSampleRate)) Hz, \(frameCount) frames"

                XCTAssertLessThanOrEqual(
                    configuration.targetFillFrames,
                    configuration.maximumTargetFillFrames,
                    routeDescription
                )
                XCTAssertLessThan(
                    configuration.maximumTargetFillFrames,
                    configuration.ringCapacityFrames,
                    routeDescription
                )
                XCTAssertLessThanOrEqual(
                    configuration.estimatedApplicationLatencySeconds,
                    configuration.maximumApplicationLatencySeconds,
                    routeDescription
                )
                if configuration.isLowLatency {
                    XCTAssertLessThanOrEqual(
                        configuration.maximumApplicationLatencySeconds,
                        AsyncSRCBufferSizing.maximumApplicationLatencySeconds,
                        routeDescription
                    )
                } else {
                    encounteredFallback = true
                    XCTAssertGreaterThan(
                        configuration.estimatedApplicationLatencySeconds,
                        AsyncSRCBufferSizing.maximumApplicationLatencySeconds,
                        "Fallback must expose a concrete latency above the strict ceiling: \(routeDescription)"
                    )
                }
            }
        }
        XCTAssertTrue(
            encounteredFallback,
            "The matrix must exercise the explicit fallback above 10 ms"
        )

        let preferredConfiguration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 64,
            outputBufferFrames: 64,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )
        XCTAssertLessThanOrEqual(
            preferredConfiguration.estimatedApplicationLatencySeconds,
            AsyncSRCBufferSizing.preferredApplicationLatencySeconds
        )
    }

    func testBufferSizingIsPowerOfTwoAndIncludesPrimingHeadroom() {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 512,
            outputBufferFrames: 512,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )

        XCTAssertEqual(
            configuration.ringCapacityFrames
                & (configuration.ringCapacityFrames - 1),
            0
        )
        XCTAssertGreaterThan(configuration.ringCapacityFrames, configuration.targetFillFrames)
        XCTAssertEqual(configuration.targetFillFrames, 1_618)
        XCTAssertFalse(configuration.isLowLatency)
        XCTAssertGreaterThan(configuration.estimatedApplicationLatencySeconds, 0.03)
        XCTAssertGreaterThanOrEqual(configuration.maximumInputFrames, 512)
        XCTAssertGreaterThanOrEqual(configuration.maximumOutputFrames, 512)
    }

    func test64FrameSizingStaysWithinFiveMillisecondsIncludingFIFOOscillation() {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 64,
            outputBufferFrames: 64,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )

        XCTAssertTrue(configuration.isLowLatency)
        XCTAssertLessThanOrEqual(
            configuration.estimatedApplicationLatencySeconds,
            AsyncSRCBufferSizing.preferredApplicationLatencySeconds
        )
        XCTAssertLessThanOrEqual(
            configuration.maximumApplicationLatencySeconds,
            AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
        XCTAssertLessThan(
            configuration.targetFillFrames,
            configuration.maximumTargetFillFrames
        )
    }

    func test128FrameSizingUsesStableTenMillisecondMarginWhenNeeded() {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 128,
            outputBufferFrames: 128,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )

        XCTAssertTrue(configuration.isLowLatency)
        XCTAssertGreaterThan(
            configuration.estimatedApplicationLatencySeconds,
            AsyncSRCBufferSizing.preferredApplicationLatencySeconds
        )
        XCTAssertLessThanOrEqual(
            configuration.maximumApplicationLatencySeconds,
            AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
    }

    func testLatencyEstimateUsesConfiguredQuantumBeforeCallbacksAndLargerObservedQuantum() {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 64,
            outputBufferFrames: 64,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100,
            converterLatencySeconds: 0.000_5
        )
        let preStartLatency = AsyncSRCBufferSizing.applicationLatencySeconds(
            targetFillFrames: configuration.targetFillFrames,
            configuredInputQuantumFrames: 64,
            observedInputQuantumFrames: 0,
            readableFrames: 0,
            inputSampleRate: 48_000,
            converterLatencySeconds: 0.000_5
        )
        let partialCallbackLatency = AsyncSRCBufferSizing.applicationLatencySeconds(
            targetFillFrames: configuration.targetFillFrames,
            configuredInputQuantumFrames: 64,
            observedInputQuantumFrames: 32,
            readableFrames: 0,
            inputSampleRate: 48_000,
            converterLatencySeconds: 0.000_5
        )
        let largerCallbackLatency = AsyncSRCBufferSizing.applicationLatencySeconds(
            targetFillFrames: configuration.targetFillFrames,
            configuredInputQuantumFrames: 64,
            observedInputQuantumFrames: 128,
            readableFrames: 0,
            inputSampleRate: 48_000,
            converterLatencySeconds: 0.000_5
        )

        XCTAssertEqual(
            preStartLatency,
            configuration.estimatedApplicationLatencySeconds,
            accuracy: 0.000_001
        )
        XCTAssertEqual(partialCallbackLatency, preStartLatency, accuracy: 0.000_001)
        XCTAssertGreaterThan(largerCallbackLatency, preStartLatency)
    }

    func testCallbackDeadlineDetectionUsesObservedFramesAndSampleRate() {
        XCTAssertFalse(
            AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                executionNanoseconds: 1_000_000,
                frameCount: 64,
                sampleRate: 48_000
            )
        )
        XCTAssertTrue(
            AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                executionNanoseconds: 1_400_000,
                frameCount: 64,
                sampleRate: 48_000
            )
        )
        XCTAssertFalse(
            AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                executionNanoseconds: 1_400_000,
                frameCount: 0,
                sampleRate: 48_000
            )
        )
    }

    func testRecordedDeadlineMissCannotBeMaskedByLargerCallback() throws {
        let placeholderAudioUnit = try XCTUnwrap(AudioUnit(bitPattern: 1))
        let renderer = AsyncSRCTestInputRenderer()
        renderer.delayMicroseconds = deadlineTestDelayMicroseconds
        let rendererContext = Unmanaged.passUnretained(renderer).toOpaque()
        let context = try XCTUnwrap(
            ScreamBarAsyncSRCContextCreateWithInputRenderProc(
                asyncSRCTestInputRenderCallback,
                rendererContext,
                placeholderAudioUnit,
                1,
                1,
                128,
                128,
                1_024,
                256,
                480,
                608,
                48_000,
                44_100,
                true,
                true
            )
        )
        defer { ScreamBarAsyncSRCContextDestroy(context) }
        var actionFlags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .hostTimeValid
        timestamp.mHostTime = AudioGetCurrentHostTime()

        XCTAssertEqual(
            ScreamBarAsyncSRCInputCallback(
                UnsafeMutableRawPointer(context),
                &actionFlags,
                &timestamp,
                0,
                64,
                nil
            ),
            noErr
        )
        var metricsAfterMiss = ScreamBarAsyncSRCMetrics()
        ScreamBarAsyncSRCCopyMetrics(context, &metricsAfterMiss)
        XCTAssertGreaterThan(metricsAfterMiss.input_callback_deadline_miss_count, 0)

        renderer.delayMicroseconds = 0
        timestamp.mHostTime = AudioGetCurrentHostTime()
        XCTAssertEqual(
            ScreamBarAsyncSRCInputCallback(
                UnsafeMutableRawPointer(context),
                &actionFlags,
                &timestamp,
                0,
                128,
                nil
            ),
            noErr
        )
        var metricsAfterLargerCallback = ScreamBarAsyncSRCMetrics()
        ScreamBarAsyncSRCCopyMetrics(context, &metricsAfterLargerCallback)
        let metrics = AsyncSRCMetrics(metricsAfterLargerCallback)

        XCTAssertEqual(metrics.maximumInputCallbackFrames, 128)
        XCTAssertGreaterThanOrEqual(
            metrics.inputCallbackDeadlineMissCount,
            metricsAfterMiss.input_callback_deadline_miss_count
        )
        XCTAssertTrue(metrics.hasMissedCallbackDeadline)
    }

    func testInputCallbackEnforcesFixedReadableFrameCeilingImmediately() throws {
        let placeholderAudioUnit = try XCTUnwrap(AudioUnit(bitPattern: 1))
        let renderer = AsyncSRCTestInputRenderer()
        let rendererContext = Unmanaged.passUnretained(renderer).toOpaque()
        let configuredInputQuantum: UInt32 = 64
        let callbackFrameCount: UInt32 = 128
        let callbackCount: UInt32 = 4
        let bufferConfiguration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: configuredInputQuantum,
            outputBufferFrames: configuredInputQuantum,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )
        let context = try XCTUnwrap(
            ScreamBarAsyncSRCContextCreateWithInputRenderProc(
                asyncSRCTestInputRenderCallback,
                rendererContext,
                placeholderAudioUnit,
                1,
                1,
                bufferConfiguration.maximumInputFrames,
                bufferConfiguration.maximumOutputFrames,
                bufferConfiguration.ringCapacityFrames,
                bufferConfiguration.targetFillFrames,
                bufferConfiguration.maximumTargetFillFrames,
                bufferConfiguration.maximumReadableFrames,
                48_000,
                44_100,
                true,
                true
            )
        )
        defer { ScreamBarAsyncSRCContextDestroy(context) }
        var actionFlags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .hostTimeValid

        for _ in 0..<callbackCount {
            timestamp.mHostTime = AudioGetCurrentHostTime()
            XCTAssertEqual(
                ScreamBarAsyncSRCInputCallback(
                    UnsafeMutableRawPointer(context),
                    &actionFlags,
                    &timestamp,
                    0,
                    callbackFrameCount,
                    nil
                ),
                noErr
            )
        }

        var rawMetrics = ScreamBarAsyncSRCMetrics()
        ScreamBarAsyncSRCCopyMetrics(context, &rawMetrics)
        let metrics = AsyncSRCMetrics(rawMetrics)

        let attemptedFrameCount = callbackCount * callbackFrameCount
        let expectedDroppedFrameCount = attemptedFrameCount
            - bufferConfiguration.maximumReadableFrames
        XCTAssertGreaterThan(callbackFrameCount, configuredInputQuantum)
        XCTAssertLessThanOrEqual(
            bufferConfiguration.maximumApplicationLatencySeconds,
            AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
        XCTAssertEqual(
            metrics.readableFrames,
            bufferConfiguration.maximumReadableFrames
        )
        XCTAssertEqual(
            metrics.capturedFrames,
            UInt64(bufferConfiguration.maximumReadableFrames)
        )
        XCTAssertEqual(
            metrics.droppedInputFrames,
            UInt64(expectedDroppedFrameCount)
        )
        XCTAssertEqual(metrics.maximumInputCallbackFrames, callbackFrameCount)
        XCTAssertEqual(metrics.latencyCeilingOverflowCount, 1)
        XCTAssertEqual(metrics.overflowCount, 0)
        XCTAssertTrue(metrics.hasRuntimeErrors)
        XCTAssertTrue(
            LegacyCoreAudioBackend.requiresBufferEscalation(
                metrics: metrics,
                callbackExceededConfiguredQuantum: false,
                missedCallbackDeadline: false
            )
        )
    }

    func testSizingFallsBackToConcreteSafeLatencyAbove128Frames() {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 256,
            outputBufferFrames: 256,
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )

        XCTAssertFalse(configuration.isLowLatency)
        XCTAssertGreaterThan(
            configuration.estimatedApplicationLatencySeconds,
            AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
        XCTAssertEqual(configuration.targetFillFrames, 827)
    }

    func testUpsamplingStaysUnderHardLimitWhenFiveMillisecondsIsImpossible() {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: 64,
            outputBufferFrames: 64,
            inputSampleRate: 44_100,
            outputSampleRate: 48_000
        )

        XCTAssertTrue(configuration.isLowLatency)
        XCTAssertGreaterThan(
            configuration.estimatedApplicationLatencySeconds,
            AsyncSRCBufferSizing.preferredApplicationLatencySeconds
        )
        XCTAssertLessThanOrEqual(
            configuration.maximumApplicationLatencySeconds,
            AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
    }

    func testAutomaticBufferPolicyPrefers64ThenFallsBackDeterministically() throws {
        let input = makeBufferDevice(uid: "input", minimumFrames: 64)
        let output = makeBufferDevice(uid: "output", minimumFrames: 128)

        XCTAssertEqual(
            try AsyncSRCLowLatencyPolicy.resolveBufferFrameSize(
                requestedFrameCount: nil,
                input: input,
                output: output
            ),
            128
        )

        let fallbackInput = makeBufferDevice(uid: "fallback-input", minimumFrames: 256)
        let fallbackOutput = makeBufferDevice(uid: "fallback-output", minimumFrames: 256)
        XCTAssertEqual(
            try AsyncSRCLowLatencyPolicy.resolveBufferFrameSize(
                requestedFrameCount: nil,
                input: fallbackInput,
                output: fallbackOutput
            ),
            256
        )
    }

    func testMaximumSourceFramesCoversMaximumPlaybackCorrection() {
        let maximumSourceFrames = ScreamBarAsyncSRCMaximumSourceFrames(
            4_096,
            192_000,
            32_000
        )

        XCTAssertEqual(maximumSourceFrames, 24_677)
    }

    func testCallbackFrameLimitTelemetryIsReportedAsRuntimeError() throws {
        let placeholderAudioUnit = try XCTUnwrap(AudioUnit(bitPattern: 1))
        let context = try XCTUnwrap(
            ScreamBarAsyncSRCContextCreate(
                placeholderAudioUnit,
                placeholderAudioUnit,
                1,
                1,
                128,
                128,
                1_024,
                256,
                480,
                608,
                48_000,
                44_100,
                true,
                true
            )
        )
        defer { ScreamBarAsyncSRCContextDestroy(context) }
        var actionFlags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .hostTimeValid
        timestamp.mHostTime = AudioConvertNanosToHostTime(1_000_000)
        let callbackContext = UnsafeMutableRawPointer(context)

        XCTAssertEqual(
            ScreamBarAsyncSRCInputCallback(
                callbackContext,
                &actionFlags,
                &timestamp,
                0,
                129,
                nil
            ),
            kAudio_ParamError
        )
        XCTAssertEqual(
            ScreamBarAsyncSRCOutputCallback(
                callbackContext,
                &actionFlags,
                &timestamp,
                0,
                129,
                nil
            ),
            noErr
        )
        timestamp.mHostTime = AudioConvertNanosToHostTime(3_000_000)
        _ = ScreamBarAsyncSRCInputCallback(
            callbackContext,
            &actionFlags,
            &timestamp,
            0,
            129,
            nil
        )
        _ = ScreamBarAsyncSRCOutputCallback(
            callbackContext,
            &actionFlags,
            &timestamp,
            0,
            129,
            nil
        )

        var rawMetrics = ScreamBarAsyncSRCMetrics()
        ScreamBarAsyncSRCCopyMetrics(context, &rawMetrics)
        let metrics = AsyncSRCMetrics(rawMetrics)

        XCTAssertEqual(metrics.inputCallbackFrameLimitExceededCount, 2)
        XCTAssertEqual(metrics.outputCallbackFrameLimitExceededCount, 2)
        XCTAssertTrue(metrics.hasRuntimeErrors)
        XCTAssertGreaterThan(metrics.maximumInputCallbackGapNanoseconds, 0)
        XCTAssertGreaterThan(metrics.maximumOutputCallbackGapNanoseconds, 0)
        XCTAssertGreaterThan(
            max(
                metrics.maximumInputCallbackExecutionNanoseconds,
                metrics.maximumOutputCallbackExecutionNanoseconds
            ),
            0,
            "At least one callback must exercise execution-time telemetry; a trivial callback may complete within one host-time tick"
        )
    }

    func testStartupTrimDoesNotHideRuntimeResynchronizationOrOverflow() {
        var rawMetrics = ScreamBarAsyncSRCMetrics()
        rawMetrics.startup_trim_count = 1
        rawMetrics.startup_trimmed_frames = 2_048
        let startupMetrics = AsyncSRCMetrics(rawMetrics)

        XCTAssertEqual(startupMetrics.startupTrimCount, 1)
        XCTAssertEqual(startupMetrics.startupTrimmedFrames, 2_048)
        XCTAssertEqual(startupMetrics.resynchronizationCount, 0)
        XCTAssertFalse(
            LegacyCoreAudioBackend.requiresBufferEscalation(
                metrics: startupMetrics,
                callbackExceededConfiguredQuantum: false,
                missedCallbackDeadline: false
            )
        )
        XCTAssertTrue(
            LegacyCoreAudioBackend.bufferEscalationReasons(
                metrics: startupMetrics,
                callbackExceededConfiguredQuantum: false,
                missedCallbackDeadline: false
            ).isEmpty
        )

        rawMetrics.resynchronization_count = 1
        let runtimeResynchronizationMetrics = AsyncSRCMetrics(rawMetrics)
        XCTAssertTrue(
            LegacyCoreAudioBackend.requiresBufferEscalation(
                metrics: runtimeResynchronizationMetrics,
                callbackExceededConfiguredQuantum: false,
                missedCallbackDeadline: false
            )
        )
        XCTAssertEqual(
            LegacyCoreAudioBackend.bufferEscalationReasons(
                metrics: runtimeResynchronizationMetrics,
                callbackExceededConfiguredQuantum: false,
                missedCallbackDeadline: false
            ),
            ["FIFO resynchronizations: 1"]
        )

        rawMetrics.resynchronization_count = 0
        rawMetrics.overflow_count = 1
        let overflowMetrics = AsyncSRCMetrics(rawMetrics)
        XCTAssertTrue(
            LegacyCoreAudioBackend.requiresBufferEscalation(
                metrics: overflowMetrics,
                callbackExceededConfiguredQuantum: false,
                missedCallbackDeadline: false
            )
        )
    }

    func testStabilityCheckpointIgnoresOnlyPreviouslyObservedDisruptions() {
        var rawMetrics = ScreamBarAsyncSRCMetrics()
        rawMetrics.underrun_count = 2
        rawMetrics.latency_ceiling_underrun_count = 2
        rawMetrics.input_callback_deadline_miss_count = 1
        let checkpointMetrics = AsyncSRCMetrics(rawMetrics)
        let checkpoint = AsyncSRCStabilityCounters(metrics: checkpointMetrics)

        XCTAssertTrue(
            LegacyCoreAudioBackend.bufferEscalationReasons(
                metrics: checkpointMetrics,
                since: checkpoint
            ).isEmpty
        )

        rawMetrics.underrun_count = 3
        rawMetrics.latency_ceiling_underrun_count = 3
        rawMetrics.input_callback_deadline_miss_count = 2
        let newMetrics = AsyncSRCMetrics(rawMetrics)
        XCTAssertEqual(
            LegacyCoreAudioBackend.bufferEscalationReasons(
                metrics: newMetrics,
                since: checkpoint
            ),
            [
                "FIFO underruns at latency ceiling: 1",
                "callback execution exceeded its real-time deadline",
            ]
        )
        XCTAssertEqual(
            AsyncSRCStabilityCounters(metrics: newMetrics)
                .subtracting(checkpoint)
                .totalIncidentCount,
            2
        )
    }

    func testAnyRuntimeUnderrunIsAnActionableSensitivityIncident() {
        var rawMetrics = ScreamBarAsyncSRCMetrics()
        rawMetrics.underrun_count = 1

        XCTAssertEqual(
            LegacyCoreAudioBackend.bufferEscalationReasons(
                metrics: AsyncSRCMetrics(rawMetrics),
                since: .zero
            ),
            ["FIFO underruns: 1"]
        )
    }

    func testConvertedPlaythroughTopologyAndClientFormatAreDeterministic() {
        XCTAssertEqual(AsyncSRCPlaythroughTopology.inputElement, 1)
        XCTAssertEqual(AsyncSRCPlaythroughTopology.outputElement, 0)
        XCTAssertEqual(AsyncSRCPlaythroughTopology.inputEnableScope, kAudioUnitScope_Input)
        XCTAssertEqual(AsyncSRCPlaythroughTopology.outputEnableScope, kAudioUnitScope_Output)

        let format = AsyncSRCPlaythrough.makeClientFormat(
            sampleRate: 48_000,
            channelCount: 2
        )
        XCTAssertEqual(format.mSampleRate, 48_000)
        XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(format.mBitsPerChannel, 32)
        XCTAssertNotEqual(format.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertNotEqual(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
    }


    private func makeBufferDevice(
        uid: String,
        minimumFrames: UInt32
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: uid,
            inputChannelCount: 2,
            outputChannelCount: 2,
            isAlive: true,
            currentNominalSampleRate: 48_000,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 48_000, maximum: 48_000),
            ],
            currentBufferFrameSize: 512,
            supportedBufferFrameSizeRange: AudioBufferFrameSizeRange(
                minimum: minimumFrames,
                maximum: 2_048
            )
        )
    }


    @discardableResult
    private func assertStableTiming(
        inputSampleRate: Double,
        outputSampleRate: Double,
        frameCount: UInt32,
        inputDriftPartsPerMillion: Double,
        maximumJitterSeconds: Double,
        includesInputBursts: Bool = false
    ) throws -> Double {
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: frameCount,
            outputBufferFrames: frameCount,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }

        let driftScalar = 1 + inputDriftPartsPerMillion / 1_000_000
        let inputPeriod = Double(frameCount) / (inputSampleRate * driftScalar)
        let outputPeriod = Double(frameCount) / outputSampleRate
        let controllerTargetFillFrames = includesInputBursts
            ? configuration.maximumTargetFillFrames
            : configuration.targetFillFrames
        let primingThreshold = controllerTargetFillFrames
            + min(
                frameCount / 2,
                configuration.maximumTargetFillFrames
                    - controllerTargetFillFrames
            )
        var readableFrames = Double(
            ((primingThreshold + frameCount - 1) / frameCount) * frameCount
        )
        var inputCallbackIndex = 1
        var outputCallbackIndex = 0
        var nextInputTime = inputPeriod
        var outputTime = 0.0
        var minimumReadableFrames = readableFrames
        var maximumReadableFrames = readableFrames
        var modeledUnderrunCount = 0
        var modeledOverflowCount = 0
        var maximumInputCallbacksPerOutput = 0
        var finalPlaybackRates: [Double] = []

        while outputTime < Self.simulatedDurationSeconds {
            var inputCallbacksThisOutput = 0
            while nextInputTime <= outputTime {
                readableFrames += Double(frameCount)
                maximumReadableFrames = max(maximumReadableFrames, readableFrames)
                if readableFrames > Double(configuration.ringCapacityFrames) {
                    modeledOverflowCount += 1
                }
                inputCallbackIndex += 1
                inputCallbacksThisOutput += 1
                nextInputTime = Double(inputCallbackIndex) * inputPeriod
                    + deterministicInputTimingOffset(
                        index: inputCallbackIndex,
                        inputPeriod: inputPeriod,
                        maximumJitterSeconds: maximumJitterSeconds,
                        includesBursts: includesInputBursts
                    )
            }
            maximumInputCallbacksPerOutput = max(
                maximumInputCallbacksPerOutput,
                inputCallbacksThisOutput
            )
            let playbackRate = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                UInt32(max(0, readableFrames.rounded())),
                controllerTargetFillFrames,
                frameCount,
                inputSampleRate,
                outputSampleRate,
                AsyncSRCClockControlPolicy.usesAdaptiveControl(
                    inputBufferFrames: frameCount,
                    outputBufferFrames: frameCount
                )
            )
            let consumedFrames = Double(frameCount)
                * inputSampleRate / outputSampleRate * playbackRate
            guard readableFrames >= consumedFrames else {
                modeledUnderrunCount += 1
                XCTFail(
                    "Modeled underrun at \(Int(inputSampleRate)) → \(Int(outputSampleRate)) Hz, \(frameCount) frames, drift \(inputDriftPartsPerMillion) ppm, jitter \(maximumJitterSeconds * 1_000) ms, time=\(outputTime), rate=\(playbackRate); readable=\(readableFrames), required=\(consumedFrames)"
                )
                return playbackRate
            }
            readableFrames -= consumedFrames
            if outputTime >= Self.simulatedDurationSeconds - 5 {
                finalPlaybackRates.append(playbackRate)
            }
            minimumReadableFrames = min(minimumReadableFrames, readableFrames)
            maximumReadableFrames = max(maximumReadableFrames, readableFrames)
            outputCallbackIndex += 1
            outputTime = Double(outputCallbackIndex) * outputPeriod
                + deterministicJitter(
                    index: outputCallbackIndex,
                    phase: 1.91,
                    amplitudeSeconds: maximumJitterSeconds
                )
        }

        XCTAssertEqual(modeledUnderrunCount, 0)
        XCTAssertEqual(modeledOverflowCount, 0)
        XCTAssertGreaterThanOrEqual(minimumReadableFrames, 0)
        XCTAssertLessThanOrEqual(
            maximumReadableFrames,
            Double(configuration.ringCapacityFrames)
        )
        if includesInputBursts {
            XCTAssertGreaterThanOrEqual(maximumInputCallbacksPerOutput, 2)
        }
        if configuration.isLowLatency {
            XCTAssertLessThanOrEqual(
                configuration.maximumApplicationLatencySeconds,
                AsyncSRCBufferSizing.maximumApplicationLatencySeconds
            )
        }
        XCTAssertFalse(finalPlaybackRates.isEmpty)
        return finalPlaybackRates.reduce(0, +)
            / Double(finalPlaybackRates.count)
    }

    private func deterministicInputTimingOffset(
        index: Int,
        inputPeriod: Double,
        maximumJitterSeconds: Double,
        includesBursts: Bool
    ) -> Double {
        let burstDelay = includesBursts && index.isMultiple(of: 211)
            ? inputPeriod * 0.5
            : 0
        return deterministicJitter(
            index: index,
            phase: 0.37,
            amplitudeSeconds: maximumJitterSeconds
        ) + burstDelay
    }

    private func deterministicJitter(
        index: Int,
        phase: Double,
        amplitudeSeconds: Double
    ) -> Double {
        sin(Double(index) * 0.731 + phase)
            * amplitudeSeconds
    }

    private func inputPeriod(
        frameCount: UInt32,
        sampleRate: Double,
        driftPartsPerMillion: Double
    ) -> Double {
        let driftScalar = 1 + driftPartsPerMillion / 1_000_000
        return Double(frameCount) / (sampleRate * driftScalar)
    }

    private func requestedTimingSoakDuration() -> TimeInterval {
        guard let rawDuration = ProcessInfo.processInfo.environment[
            Self.timingSoakEnvironmentKey
        ], let duration = TimeInterval(rawDuration), duration > 0 else {
            return 0
        }
        return duration
    }
}
