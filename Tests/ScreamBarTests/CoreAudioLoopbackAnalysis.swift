import Accelerate
import AudioToolbox
import Darwin.Mach
import Foundation

struct CoreAudioLoopbackTimestamp: Equatable {
    let frameOffset: UInt64
    let frameCount: UInt32
    let hostTime: UInt64
    let sampleTime: Double
    let flags: UInt32

    var hasValidHostTime: Bool {
        flags & AudioTimeStampFlags.hostTimeValid.rawValue != 0
    }
}

struct CoreAudioLoopbackMeasurement: Codable, Equatable {
    let markerIndex: Int
    let outputFrameOffset: UInt64
    let detectedInputFrame: Int
    let sampleOffset: Double
    let latencyMilliseconds: Double
    let normalizedCorrelation: Double
    let peakToSidelobeRatio: Double
}

struct CoreAudioLoopbackAnalysisResult: Equatable {
    let measurements: [CoreAudioLoopbackMeasurement]
    let missedMarkerIndices: [Int]
    let ambiguousMarkerIndices: [Int]
    let duplicateMarkerIndices: [Int]
    let invalidTimestampMarkerIndices: [Int]
    let inconsistentMarkerIndices: [Int]

    var isComplete: Bool {
        missedMarkerIndices.isEmpty
            && ambiguousMarkerIndices.isEmpty
            && duplicateMarkerIndices.isEmpty
            && invalidTimestampMarkerIndices.isEmpty
    }
}

enum CoreAudioLoopbackAnalyzer {
    private static let nanosecondsPerSecond = 1_000_000_000.0
    private static let earlySearchSeconds = 0.010
    private static let inconsistentFloorMilliseconds = 2.0
    private static let inconsistentMADMultiplier = 6.0

    static func analyze(
        capture: [Float],
        marker: [Float],
        markerFrameOffsets: [UInt64],
        inputTimestamps: [CoreAudioLoopbackTimestamp],
        outputTimestamps: [CoreAudioLoopbackTimestamp],
        sampleRate: Double,
        maximumLatencySeconds: Double,
        minimumCorrelation: Double,
        minimumPeakToSidelobeRatio: Double
    ) -> CoreAudioLoopbackAnalysisResult {
        guard capture.count >= marker.count,
              !marker.isEmpty,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return CoreAudioLoopbackAnalysisResult(
                measurements: [],
                missedMarkerIndices: Array(markerFrameOffsets.indices),
                ambiguousMarkerIndices: [],
                duplicateMarkerIndices: [],
                invalidTimestampMarkerIndices: [],
                inconsistentMarkerIndices: []
            )
        }

        let correlations = crossCorrelations(capture: capture, marker: marker)
        let captureEnergyPrefix = energyPrefix(samples: capture)
        let markerEnergy = marker.reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        let ticksPerSecond = hostTicksPerSecond()
        let validInputTimestamps = inputTimestamps.filter(\.hasValidHostTime)
        let validOutputTimestamps = outputTimestamps.filter(\.hasValidHostTime)
        var measurements: [CoreAudioLoopbackMeasurement] = []
        var missedMarkerIndices: [Int] = []
        var ambiguousMarkerIndices: [Int] = []
        var invalidTimestampMarkerIndices: [Int] = []

        for (markerIndex, markerFrameOffset) in markerFrameOffsets.enumerated() {
            guard let outputHostTime = hostTime(
                forFrame: markerFrameOffset,
                timestamps: validOutputTimestamps,
                sampleRate: sampleRate,
                ticksPerSecond: ticksPerSecond
            ), let predictedInputFrame = frameOffset(
                atHostTime: outputHostTime,
                timestamps: validInputTimestamps,
                sampleRate: sampleRate,
                ticksPerSecond: ticksPerSecond
            ) else {
                invalidTimestampMarkerIndices.append(markerIndex)
                continue
            }

            let searchStart = max(
                0,
                Int(floor(
                    predictedInputFrame
                        - Self.earlySearchSeconds * sampleRate
                ))
            )
            let searchEnd = min(
                correlations.count,
                Int(ceil(
                    predictedInputFrame
                        + maximumLatencySeconds * sampleRate
                )) + 1
            )
            guard searchStart < searchEnd,
                  let peak = bestPeak(
                    correlations: correlations,
                    energyPrefix: captureEnergyPrefix,
                    markerEnergy: markerEnergy,
                    markerFrameCount: marker.count,
                    searchRange: searchStart..<searchEnd
                  ) else {
                missedMarkerIndices.append(markerIndex)
                continue
            }
            guard peak.normalizedCorrelation >= minimumCorrelation else {
                missedMarkerIndices.append(markerIndex)
                continue
            }
            guard peak.peakToSidelobeRatio
                    >= minimumPeakToSidelobeRatio else {
                ambiguousMarkerIndices.append(markerIndex)
                continue
            }
            let sampleOffset = Double(peak.frameIndex) - predictedInputFrame
            guard sampleOffset >= 0,
                  sampleOffset <= maximumLatencySeconds * sampleRate else {
                missedMarkerIndices.append(markerIndex)
                continue
            }
            measurements.append(
                CoreAudioLoopbackMeasurement(
                    markerIndex: markerIndex,
                    outputFrameOffset: markerFrameOffset,
                    detectedInputFrame: peak.frameIndex,
                    sampleOffset: sampleOffset,
                    latencyMilliseconds: sampleOffset / sampleRate * 1_000,
                    normalizedCorrelation: peak.normalizedCorrelation,
                    peakToSidelobeRatio: peak.peakToSidelobeRatio
                )
            )
        }

        let duplicateMarkerIndices = duplicateIndices(in: measurements)
        let inconsistentMarkerIndices = inconsistentIndices(in: measurements)
        return CoreAudioLoopbackAnalysisResult(
            measurements: measurements,
            missedMarkerIndices: missedMarkerIndices,
            ambiguousMarkerIndices: ambiguousMarkerIndices,
            duplicateMarkerIndices: duplicateMarkerIndices,
            invalidTimestampMarkerIndices: invalidTimestampMarkerIndices,
            inconsistentMarkerIndices: inconsistentMarkerIndices
        )
    }

    static func percentile(_ sortedValues: [Double], probability: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let boundedProbability = min(max(probability, 0), 1)
        let rank = max(
            0,
            Int(ceil(boundedProbability * Double(sortedValues.count))) - 1
        )
        return sortedValues[min(rank, sortedValues.count - 1)]
    }

    private static func crossCorrelations(
        capture: [Float],
        marker: [Float]
    ) -> [Float] {
        let resultCount = capture.count - marker.count + 1
        var correlations = [Float](repeating: 0, count: resultCount)
        capture.withUnsafeBufferPointer { captureBuffer in
            marker.withUnsafeBufferPointer { markerBuffer in
                correlations.withUnsafeMutableBufferPointer { outputBuffer in
                    vDSP_conv(
                        captureBuffer.baseAddress!,
                        1,
                        markerBuffer.baseAddress!,
                        1,
                        outputBuffer.baseAddress!,
                        1,
                        vDSP_Length(resultCount),
                        vDSP_Length(marker.count)
                    )
                }
            }
        }
        return correlations
    }

    private static func energyPrefix(samples: [Float]) -> [Double] {
        var prefix = [Double](repeating: 0, count: samples.count + 1)
        for sampleIndex in samples.indices {
            let sample = Double(samples[sampleIndex])
            prefix[sampleIndex + 1] = prefix[sampleIndex] + sample * sample
        }
        return prefix
    }

    private static func bestPeak(
        correlations: [Float],
        energyPrefix: [Double],
        markerEnergy: Double,
        markerFrameCount: Int,
        searchRange: Range<Int>
    ) -> (frameIndex: Int, normalizedCorrelation: Double, peakToSidelobeRatio: Double)? {
        guard markerEnergy > 0 else { return nil }
        var scores: [(frameIndex: Int, score: Double)] = []
        scores.reserveCapacity(searchRange.count)
        for frameIndex in searchRange {
            let captureEnergy = energyPrefix[frameIndex + markerFrameCount]
                - energyPrefix[frameIndex]
            let denominator = sqrt(markerEnergy * max(captureEnergy, 0))
            let score = denominator > 0
                ? abs(Double(correlations[frameIndex])) / denominator
                : 0
            scores.append((frameIndex, score))
        }
        guard let peak = scores.max(by: { $0.score < $1.score }) else {
            return nil
        }
        let exclusionRadius = max(1, markerFrameCount / 4)
        let sidelobe = scores.lazy
            .filter { abs($0.frameIndex - peak.frameIndex) > exclusionRadius }
            .map(\.score)
            .max() ?? 0
        let ratio = sidelobe > 0 ? peak.score / sidelobe : .infinity
        return (peak.frameIndex, peak.score, ratio)
    }

    private static func hostTime(
        forFrame frame: UInt64,
        timestamps: [CoreAudioLoopbackTimestamp],
        sampleRate: Double,
        ticksPerSecond: Double
    ) -> Double? {
        guard let timestamp = timestamps.first(where: {
            frame >= $0.frameOffset
                && frame < $0.frameOffset + UInt64($0.frameCount)
        }) else {
            return nil
        }
        let localFrameOffset = Double(frame - timestamp.frameOffset)
        return Double(timestamp.hostTime)
            + localFrameOffset / sampleRate * ticksPerSecond
    }

    private static func frameOffset(
        atHostTime hostTime: Double,
        timestamps: [CoreAudioLoopbackTimestamp],
        sampleRate: Double,
        ticksPerSecond: Double
    ) -> Double? {
        guard let timestamp = timestamps.min(by: {
            abs(Double($0.hostTime) - hostTime)
                < abs(Double($1.hostTime) - hostTime)
        }) else {
            return nil
        }
        return Double(timestamp.frameOffset)
            + (hostTime - Double(timestamp.hostTime))
                / ticksPerSecond * sampleRate
    }

    private static func hostTicksPerSecond() -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Self.nanosecondsPerSecond
            * Double(timebase.denom)
            / Double(timebase.numer)
    }

    private static func duplicateIndices(
        in measurements: [CoreAudioLoopbackMeasurement]
    ) -> [Int] {
        var firstMarkerByInputFrame: [Int: Int] = [:]
        var duplicates: [Int] = []
        for measurement in measurements {
            if firstMarkerByInputFrame[measurement.detectedInputFrame] != nil {
                duplicates.append(measurement.markerIndex)
            } else {
                firstMarkerByInputFrame[measurement.detectedInputFrame] =
                    measurement.markerIndex
            }
        }
        return duplicates
    }

    private static func inconsistentIndices(
        in measurements: [CoreAudioLoopbackMeasurement]
    ) -> [Int] {
        let latencies = measurements
            .map(\.latencyMilliseconds)
            .sorted()
        guard let median = percentile(latencies, probability: 0.5) else {
            return []
        }
        let deviations = latencies
            .map { abs($0 - median) }
            .sorted()
        let medianAbsoluteDeviation =
            percentile(deviations, probability: 0.5) ?? 0
        let threshold = max(
            Self.inconsistentFloorMilliseconds,
            medianAbsoluteDeviation * Self.inconsistentMADMultiplier
        )
        return measurements.compactMap { measurement in
            abs(measurement.latencyMilliseconds - median) > threshold
                ? measurement.markerIndex
                : nil
        }
    }
}
