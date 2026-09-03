@testable import ScreamBar
import AudioToolbox
import Foundation
import ScreamBarCoreAudioRT
import XCTest

final class CoreAudioLongSoakSupportTests: XCTestCase {
    func testConfigurationUsesOneHourDefaultsAndExplicitOverrides() {
        let defaults = CoreAudioLongSoakConfiguration(environment: [:])
        XCTAssertEqual(defaults.durationSeconds, 3_600)
        XCTAssertEqual(defaults.pollingIntervalNanoseconds, 500_000_000)
        XCTAssertEqual(defaults.inputName, "Cubilux SPDIF Receiver")
        XCTAssertEqual(defaults.outputName, "Bose QC 45")
        XCTAssertEqual(defaults.minimumOutputChanges, 2)

        let overrides = CoreAudioLongSoakConfiguration(environment: [
            CoreAudioLongSoakConfiguration.durationKey: "42.5",
            CoreAudioLongSoakConfiguration.pollingIntervalKey: "125",
            CoreAudioLongSoakConfiguration.inputNameKey: "Test Input",
            CoreAudioLongSoakConfiguration.outputNameKey: "Test Output",
            CoreAudioLongSoakConfiguration.cpuWorkerCountKey: "3",
            CoreAudioLongSoakConfiguration.minimumOutputChangesKey: "4",
        ])
        XCTAssertEqual(overrides.durationSeconds, 42.5)
        XCTAssertEqual(overrides.pollingIntervalNanoseconds, 125_000_000)
        XCTAssertEqual(overrides.inputName, "Test Input")
        XCTAssertEqual(overrides.outputName, "Test Output")
        XCTAssertEqual(overrides.cpuWorkerCount, 3)
        XCTAssertEqual(overrides.minimumOutputChanges, 4)
    }

    @MainActor
    func testMultiSessionCollectorAggregatesFinalizedRoutes() throws {
        var firstRawMetrics = ScreamBarAsyncSRCMetrics()
        firstRawMetrics.captured_frames = 1_000
        firstRawMetrics.rendered_frames = 900
        firstRawMetrics.fifo_fill_sample_count = 10
        firstRawMetrics.fifo_fill_frame_sum = 400
        firstRawMetrics.minimum_fifo_fill_frames = 20
        firstRawMetrics.maximum_fifo_fill_frames = 60
        firstRawMetrics.playback_rate_adjustment_count = 3
        firstRawMetrics.minimum_playback_rate = 0.999
        firstRawMetrics.maximum_playback_rate = 1.001
        firstRawMetrics.latency_ceiling_overflow_count = 6
        firstRawMetrics.maximum_input_callback_host_time_gap =
            AudioConvertNanosToHostTime(4_000_000)
        firstRawMetrics.maximum_output_callback_host_time_gap =
            AudioConvertNanosToHostTime(6_000_000)

        var secondRawMetrics = ScreamBarAsyncSRCMetrics()
        secondRawMetrics.captured_frames = 2_000
        secondRawMetrics.rendered_frames = 1_800
        secondRawMetrics.fifo_fill_sample_count = 30
        secondRawMetrics.fifo_fill_frame_sum = 1_500
        secondRawMetrics.minimum_fifo_fill_frames = 10
        secondRawMetrics.maximum_fifo_fill_frames = 90
        secondRawMetrics.playback_rate_adjustment_count = 5
        secondRawMetrics.minimum_playback_rate = 0.998
        secondRawMetrics.maximum_playback_rate = 1.002

        let collector = CoreAudioLongSoakMultiSessionTelemetryCollector()
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(firstRawMetrics)
        )
        XCTAssertTrue(
            collector.markMostRecentlyFinalizedSessionAsExpectedInterruption(
                ifFinalizedAfter: 0
            )
        )
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(secondRawMetrics)
        )

        let telemetry = try XCTUnwrap(
            collector.makeSummary(
                latencyMinimumMilliseconds: 4,
                latencyMaximumMilliseconds: 8
            )
        )
        XCTAssertEqual(collector.finalizedSessionCount, 2)
        XCTAssertEqual(telemetry.finalizedAsyncSRCSessionCount, 2)
        XCTAssertEqual(telemetry.capturedFrames, 3_000)
        XCTAssertEqual(telemetry.renderedFrames, 2_700)
        XCTAssertEqual(telemetry.fifoFillSampleCount, 40)
        XCTAssertEqual(telemetry.fifoMinimumFillFrames, 10)
        XCTAssertEqual(telemetry.fifoMaximumFillFrames, 90)
        XCTAssertEqual(telemetry.fifoMeanFillFrames, 47.5)
        XCTAssertEqual(telemetry.srcPlaybackRateAdjustmentCount, 8)
        XCTAssertEqual(telemetry.srcPlaybackRateMinimum, 0.998)
        XCTAssertEqual(telemetry.srcPlaybackRateMaximum, 1.002)
        XCTAssertEqual(telemetry.estimatedLatencyMinimumMilliseconds, 4)
        XCTAssertEqual(telemetry.estimatedLatencyMaximumMilliseconds, 8)
        XCTAssertEqual(telemetry.latencyCeilingOverrunCount, 6)
        XCTAssertEqual(telemetry.maximumInputCallbackGapMilliseconds, 4)
        XCTAssertEqual(telemetry.maximumOutputCallbackGapMilliseconds, 6)
        XCTAssertFalse(telemetry.telemetrySaturated)
        XCTAssertEqual(collector.healthViolations.count, 1)
        XCTAssertTrue(
            collector.healthViolations[0].contains(
                "latency-ceiling FIFO overruns: 6"
            )
        )
        let recoveredHealth = collector.healthAssessment(
            policy: .classifiedExpectedInterruptions
        )
        XCTAssertTrue(recoveredHealth.violations.isEmpty)
        XCTAssertEqual(recoveredHealth.diagnostics.count, 1)
        XCTAssertTrue(
            recoveredHealth.diagnostics[0].contains("expected interruption")
        )
    }

    @MainActor
    func testExpectedInterruptionDoesNotMaskUnrelatedSessionFailure() {
        var unrelatedFailure = ScreamBarAsyncSRCMetrics()
        unrelatedFailure.input_render_error_count = 1
        var expectedInterruption = ScreamBarAsyncSRCMetrics()
        expectedInterruption.underrun_count = 1

        let collector = CoreAudioLongSoakMultiSessionTelemetryCollector()
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(unrelatedFailure)
        )
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(expectedInterruption)
        )
        XCTAssertTrue(
            collector.markMostRecentlyFinalizedSessionAsExpectedInterruption(
                ifFinalizedAfter: 1
            )
        )
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(ScreamBarAsyncSRCMetrics())
        )

        let assessment = collector.healthAssessment(
            policy: .classifiedExpectedInterruptions
        )
        XCTAssertEqual(assessment.violations.count, 1)
        XCTAssertTrue(
            assessment.violations[0].contains("input render errors: 1")
        )
        XCTAssertEqual(assessment.diagnostics.count, 1)
        XCTAssertTrue(
            assessment.diagnostics[0].contains("expected interruption")
        )
    }

    @MainActor
    func testNativeIntermediateRouteDoesNotMarkRecoveredSRCSession() {
        let collector = CoreAudioLongSoakMultiSessionTelemetryCollector()
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(ScreamBarAsyncSRCMetrics())
        )
        XCTAssertTrue(
            collector.markMostRecentlyFinalizedSessionAsExpectedInterruption(
                ifFinalizedAfter: 0
            )
        )

        let nativeRouteSessionCount = collector.finalizedSessionCount
        XCTAssertFalse(
            collector.markMostRecentlyFinalizedSessionAsExpectedInterruption(
                ifFinalizedAfter: nativeRouteSessionCount
            )
        )
        collector.recordFinalMetrics(
            sessionID: UUID(),
            metrics: AsyncSRCMetrics(ScreamBarAsyncSRCMetrics())
        )

        let assessment = collector.healthAssessment(
            policy: .classifiedExpectedInterruptions
        )
        XCTAssertTrue(assessment.violations.isEmpty)
        XCTAssertEqual(assessment.diagnostics.count, 1)
    }

    func testReportWriterProducesDecodableJSONArtifact() throws {
        let reportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: reportDirectory)
            } catch {
                XCTFail("Failed to remove report test directory: \(error)")
            }
        }
        let configuration = CoreAudioLongSoakConfiguration(environment: [
            CoreAudioLongSoakConfiguration.reportDirectoryKey:
                reportDirectory.path,
        ])
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let report = CoreAudioLongSoakReportWriter.makeReport(
            scenario: .normal,
            startedAt: startedAt,
            requestedDurationSeconds: 3_600,
            inputName: "Input",
            outputPreference: "Output",
            phases: [
                CoreAudioLongSoakPhase(
                    name: "steady-state",
                    startedAfterSeconds: 0
                ),
            ],
            pipelineRebuildCount: 0,
            effectiveOutputChangeCount: 0,
            effectiveSampleRateChangeCount: 0,
            telemetry: CoreAudioLongSoakTelemetry(),
            healthViolations: []
        )

        let reportURL = try CoreAudioLongSoakReportWriter.write(
            report,
            configuration: configuration
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedReport = try decoder.decode(
            CoreAudioLongSoakReport.self,
            from: Data(contentsOf: reportURL)
        )
        XCTAssertEqual(decodedReport.schemaVersion, report.schemaVersion)
        XCTAssertEqual(decodedReport.scenario, report.scenario)
        XCTAssertEqual(decodedReport.inputName, report.inputName)
        XCTAssertEqual(decodedReport.outputPreference, report.outputPreference)
        XCTAssertEqual(decodedReport.phases, report.phases)
        XCTAssertEqual(decodedReport.telemetry, report.telemetry)
        XCTAssertEqual(decodedReport.healthViolations, report.healthViolations)
    }
}

@MainActor
final class CoreAudioLongSoakRouteTrackerTests: XCTestCase {
    func testTrackerCountsRebuildOutputAndRateTransitions() {
        let tracker = CoreAudioLongSoakRouteTracker()
        tracker.observe(.starting)
        tracker.observe(.running(makeRoute(outputID: "first", inputRate: 48_000)))
        tracker.observe(.reconfiguring)
        tracker.observe(.running(makeRoute(outputID: "second", inputRate: 44_100)))
        tracker.observe(.reconfiguring)
        tracker.observe(.running(makeRoute(outputID: "first", inputRate: 48_000)))

        XCTAssertEqual(tracker.pipelineRebuildCount, 2)
        XCTAssertEqual(tracker.effectiveOutputChangeCount, 2)
        XCTAssertEqual(tracker.effectiveSampleRateChangeCount, 2)
        XCTAssertTrue(tracker.sawInitial48KHz)
        XCTAssertTrue(tracker.sawNon48KHzAfterInitial)
        XCTAssertTrue(tracker.sawStateAwayFromInitial48KHz)
        XCTAssertTrue(tracker.sawReturnTo48KHz)
        XCTAssertEqual(tracker.latencyMinimumMilliseconds, 4)
        XCTAssertEqual(tracker.latencyMaximumMilliseconds, 4)
        XCTAssertEqual(tracker.latencyCeilingMaximumMilliseconds, 5)
    }

    func testTrackerRecognizesInputRecovery() {
        let tracker = CoreAudioLongSoakRouteTracker()
        tracker.observe(.running(makeRoute(outputID: "output", inputRate: 48_000)))
        tracker.observe(.reconfiguring)
        tracker.observe(.waitingForInput)
        tracker.observe(.starting)
        tracker.observe(.running(makeRoute(outputID: "output", inputRate: 48_000)))

        XCTAssertTrue(tracker.sawInputUnavailable)
        XCTAssertTrue(tracker.sawInputRecovery)
        XCTAssertTrue(tracker.sawStateAwayFromInitial48KHz)
        XCTAssertTrue(tracker.sawReturnTo48KHz)
        XCTAssertEqual(tracker.pipelineRebuildCount, 2)
    }

    private func makeRoute(
        outputID: String,
        inputRate: Double
    ) -> EffectiveAudioRoute {
        let input = AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: "input"),
            name: "Input",
            inputChannelCount: 2,
            outputChannelCount: 0,
            isAlive: true,
            currentNominalSampleRate: inputRate,
            supportedNominalSampleRates: [
                NominalSampleRateRange(
                    minimum: inputRate,
                    maximum: inputRate
                ),
            ]
        )
        let output = AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: outputID),
            name: outputID,
            inputChannelCount: 0,
            outputChannelCount: 2,
            isAlive: true,
            currentNominalSampleRate: 44_100,
            supportedNominalSampleRates: [
                NominalSampleRateRange(
                    minimum: 44_100,
                    maximum: 44_100
                ),
            ]
        )
        return EffectiveAudioRoute(
            input: input,
            output: output,
            sampleRatePlan: .converted(
                inputSampleRate: inputRate,
                outputSampleRate: 44_100
            ),
            isUsingOutputFallback: false,
            bufferFrameSize: 64,
            estimatedApplicationLatencySeconds: 0.004,
            maximumApplicationLatencySeconds: 0.005,
            isLowLatency: true
        )
    }
}
