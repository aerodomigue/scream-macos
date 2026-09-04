@testable import ScreamBar
import AudioToolbox
import XCTest

final class CoreAudioLoopbackAnalysisTests: XCTestCase {
    private static let sampleRate = 48_000.0
    private static let hostTimeBase: UInt64 = 1_000_000_000

    func testSignalPlanPlacesEveryMarkerAtDeterministicOffsets() {
        let plan = CoreAudioLoopbackSignalPlan.make(
            sampleRate: Self.sampleRate,
            markerCount: 3,
            leadSilenceSeconds: 0.1,
            markerIntervalSeconds: 0.2
        )

        XCTAssertEqual(plan.markerFrameOffsets, [4_800, 14_400, 24_000])
        XCTAssertEqual(plan.outputSamples[4_800], plan.marker[0])
        XCTAssertEqual(plan.outputSamples[14_400 + 512], plan.marker[512])
    }

    func testCorrelationRecoversKnownSampleLatencyForRepeatedMarkers() {
        let plan = CoreAudioLoopbackSignalPlan.make(
            sampleRate: Self.sampleRate,
            markerCount: 4,
            leadSilenceSeconds: 0.05,
            markerIntervalSeconds: 0.1
        )
        let expectedLatencyFrames = 240
        var capture = [Float](
            repeating: 0,
            count: plan.outputSamples.count + expectedLatencyFrames + 512
        )
        for markerFrameOffset in plan.markerFrameOffsets {
            let captureOffset = Int(markerFrameOffset) + expectedLatencyFrames
            for markerIndex in plan.marker.indices {
                capture[captureOffset + markerIndex] = plan.marker[markerIndex]
            }
        }
        let timestamps = makeTimestamps(frameCount: capture.count)
        let result = CoreAudioLoopbackAnalyzer.analyze(
            capture: capture,
            marker: plan.marker,
            markerFrameOffsets: plan.markerFrameOffsets,
            inputTimestamps: timestamps,
            outputTimestamps: timestamps,
            sampleRate: Self.sampleRate,
            maximumLatencySeconds: 0.02,
            minimumCorrelation: 0.9,
            minimumPeakToSidelobeRatio: 1.1
        )

        XCTAssertEqual(result.measurements.count, 4)
        XCTAssertTrue(result.isComplete)
        for measurement in result.measurements {
            XCTAssertEqual(
                measurement.sampleOffset,
                Double(expectedLatencyFrames),
                accuracy: 0.001
            )
            XCTAssertEqual(measurement.normalizedCorrelation, 1, accuracy: 0.001)
        }
    }

    func testSilentCaptureReportsEveryMarkerAsMissed() {
        let plan = CoreAudioLoopbackSignalPlan.make(
            sampleRate: Self.sampleRate,
            markerCount: 2,
            leadSilenceSeconds: 0.05,
            markerIntervalSeconds: 0.1
        )
        let capture = [Float](repeating: 0, count: plan.outputSamples.count)
        let timestamps = makeTimestamps(frameCount: capture.count)

        let result = CoreAudioLoopbackAnalyzer.analyze(
            capture: capture,
            marker: plan.marker,
            markerFrameOffsets: plan.markerFrameOffsets,
            inputTimestamps: timestamps,
            outputTimestamps: timestamps,
            sampleRate: Self.sampleRate,
            maximumLatencySeconds: 0.02,
            minimumCorrelation: 0.5,
            minimumPeakToSidelobeRatio: 1.1
        )

        XCTAssertEqual(result.missedMarkerIndices, [0, 1])
        XCTAssertTrue(result.measurements.isEmpty)
    }

    func testMissingHostTimestampsAreReportedExplicitly() {
        let plan = CoreAudioLoopbackSignalPlan.make(
            sampleRate: Self.sampleRate,
            markerCount: 2,
            leadSilenceSeconds: 0.05,
            markerIntervalSeconds: 0.1
        )
        let capture = [Float](repeating: 0, count: plan.outputSamples.count)
        let invalidTimestamps = [
            CoreAudioLoopbackTimestamp(
                frameOffset: 0,
                frameCount: UInt32(capture.count),
                hostTime: Self.hostTimeBase,
                sampleTime: 0,
                flags: 0
            ),
        ]

        let result = CoreAudioLoopbackAnalyzer.analyze(
            capture: capture,
            marker: plan.marker,
            markerFrameOffsets: plan.markerFrameOffsets,
            inputTimestamps: invalidTimestamps,
            outputTimestamps: invalidTimestamps,
            sampleRate: Self.sampleRate,
            maximumLatencySeconds: 0.02,
            minimumCorrelation: 0.5,
            minimumPeakToSidelobeRatio: 1.1
        )

        XCTAssertEqual(result.invalidTimestampMarkerIndices, [0, 1])
        XCTAssertTrue(result.measurements.isEmpty)
    }

    func testNearestRankPercentileIsDeterministic() {
        XCTAssertEqual(
            CoreAudioLoopbackAnalyzer.percentile(
                [1, 2, 3, 4, 5],
                probability: 0.5
            ),
            3
        )
        XCTAssertEqual(
            CoreAudioLoopbackAnalyzer.percentile(
                [1, 2, 3, 4, 5],
                probability: 0.95
            ),
            5
        )
    }

    func testConfigurationSupportsDeviceAndIterationOverrides() {
        let configuration = CoreAudioLoopbackConfiguration(environment: [
            CoreAudioLoopbackConfiguration.inputNameKey: "Input Override",
            CoreAudioLoopbackConfiguration.outputNameKey: "Output Override",
            CoreAudioLoopbackConfiguration.inputUIDKey: "input.uid",
            CoreAudioLoopbackConfiguration.outputUIDKey: "output.uid",
            CoreAudioLoopbackConfiguration.iterationCountKey: "42",
        ])

        XCTAssertEqual(configuration.inputName, "Input Override")
        XCTAssertEqual(configuration.outputName, "Output Override")
        XCTAssertEqual(configuration.inputUID, "input.uid")
        XCTAssertEqual(configuration.outputUID, "output.uid")
        XCTAssertEqual(configuration.iterationCount, 42)
    }

    func testLatencyStatisticsReportNearestRankAndRange() {
        let sampleOffsets: [Double] = [1, 2, 3, 4]
        let measurements: [CoreAudioLoopbackMeasurement] =
            sampleOffsets.enumerated().map { index, sampleOffset in
                CoreAudioLoopbackMeasurement(
                    markerIndex: index,
                    outputFrameOffset: UInt64(index * 1_000),
                    detectedInputFrame: index * 1_000 + Int(sampleOffset),
                    sampleOffset: sampleOffset,
                    latencyMilliseconds: sampleOffset / 48,
                    normalizedCorrelation: 1,
                    peakToSidelobeRatio: 10
                )
            }
        let statistics = CoreAudioLoopbackLatencyStatistics(
            measurements: measurements
        )

        XCTAssertEqual(statistics?.minimumSamples, 1)
        XCTAssertEqual(statistics?.medianSamples, 2)
        XCTAssertEqual(statistics?.p95Samples, 4)
        XCTAssertEqual(statistics?.maximumSamples, 4)
        XCTAssertEqual(statistics?.jitterSamples, 3)
    }

    private func makeTimestamps(
        frameCount: Int
    ) -> [CoreAudioLoopbackTimestamp] {
        [
            CoreAudioLoopbackTimestamp(
                frameOffset: 0,
                frameCount: UInt32(frameCount),
                hostTime: Self.hostTimeBase,
                sampleTime: 0,
                flags: AudioTimeStampFlags.hostTimeValid.rawValue
            ),
        ]
    }
}
