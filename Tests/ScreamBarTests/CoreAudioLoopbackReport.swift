import Foundation
import ScreamBarLoopbackTestRT
import XCTest

struct CoreAudioLoopbackLatencyStatistics: Codable, Equatable {
    let minimumSamples: Double
    let medianSamples: Double
    let p95Samples: Double
    let maximumSamples: Double
    let jitterSamples: Double
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let jitterMilliseconds: Double

    init?(measurements: [CoreAudioLoopbackMeasurement]) {
        let sampleOffsets = measurements.map(\.sampleOffset).sorted()
        let latencyMilliseconds = measurements
            .map(\.latencyMilliseconds)
            .sorted()
        guard let minimumSamples = sampleOffsets.first,
              let maximumSamples = sampleOffsets.last,
              let medianSamples = CoreAudioLoopbackAnalyzer.percentile(
                sampleOffsets,
                probability: 0.5
              ),
              let p95Samples = CoreAudioLoopbackAnalyzer.percentile(
                sampleOffsets,
                probability: 0.95
              ),
              let minimumMilliseconds = latencyMilliseconds.first,
              let maximumMilliseconds = latencyMilliseconds.last,
              let medianMilliseconds = CoreAudioLoopbackAnalyzer.percentile(
                latencyMilliseconds,
                probability: 0.5
              ),
              let p95Milliseconds = CoreAudioLoopbackAnalyzer.percentile(
                latencyMilliseconds,
                probability: 0.95
              ) else {
            return nil
        }
        self.minimumSamples = minimumSamples
        self.medianSamples = medianSamples
        self.p95Samples = p95Samples
        self.maximumSamples = maximumSamples
        jitterSamples = maximumSamples - minimumSamples
        self.minimumMilliseconds = minimumMilliseconds
        self.medianMilliseconds = medianMilliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
        jitterMilliseconds = maximumMilliseconds - minimumMilliseconds
    }
}

struct CoreAudioLoopbackRTMetricsReport: Codable, Equatable {
    let inputRenderErrorCount: UInt64
    let inputFrameLimitExceededCount: UInt64
    let outputFrameLimitExceededCount: UInt64
    let captureOverflowFrameCount: UInt64
    let inputTimestampOverflowCount: UInt64
    let outputTimestampOverflowCount: UInt64
    let lastInputRenderStatus: Int32

    init(_ metrics: ScreamBarLoopbackRTMetrics) {
        inputRenderErrorCount = metrics.input_render_error_count
        inputFrameLimitExceededCount =
            metrics.input_frame_limit_exceeded_count
        outputFrameLimitExceededCount =
            metrics.output_frame_limit_exceeded_count
        captureOverflowFrameCount = metrics.capture_overflow_frame_count
        inputTimestampOverflowCount =
            metrics.input_timestamp_overflow_count
        outputTimestampOverflowCount =
            metrics.output_timestamp_overflow_count
        lastInputRenderStatus = metrics.last_input_render_status
    }

    var hasFailure: Bool {
        inputRenderErrorCount > 0
            || inputFrameLimitExceededCount > 0
            || outputFrameLimitExceededCount > 0
            || captureOverflowFrameCount > 0
            || inputTimestampOverflowCount > 0
            || outputTimestampOverflowCount > 0
    }
}

struct CoreAudioLoopbackLatencyReport: Codable, Equatable {
    let schemaVersion: Int
    let measurementPath: String
    let startedAt: Date
    let finishedAt: Date
    let inputName: String
    let inputUID: String
    let outputName: String
    let outputUID: String
    let inputSampleRate: Double
    let outputSampleRate: Double
    let inputPhysicalFormats: [String]
    let outputPhysicalFormats: [String]
    let clientFormat: String
    let selectedInputChannel: Int
    let requestedMarkerCount: Int
    let warmupMeasurementCount: Int
    let acceptedMeasurementCount: Int
    let missedMarkerIndices: [Int]
    let ambiguousMarkerIndices: [Int]
    let duplicateMarkerIndices: [Int]
    let invalidTimestampMarkerIndices: [Int]
    let inconsistentMarkerIndices: [Int]
    let sampleOffsets: [Double]
    let measurements: [CoreAudioLoopbackMeasurement]
    let statistics: CoreAudioLoopbackLatencyStatistics?
    let capturePeak: Double
    let captureRMS: Double
    let clippedSampleCount: Int
    let capturedFrameCount: Int
    let renderedFrameCount: UInt64
    let realtimeMetrics: CoreAudioLoopbackRTMetricsReport
    let limitations: [String]
}

enum CoreAudioLoopbackReportWriter {
    static let schemaVersion = 1
    static let measurementPath =
        "Mac CoreAudio output → Cubilux TX → TOSLINK → Cubilux RX → Mac CoreAudio input"

    @discardableResult
    static func write(
        _ report: CoreAudioLoopbackLatencyReport,
        configuration: CoreAudioLoopbackConfiguration,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directoryURL: URL
        if let configuredPath = configuration.reportDirectoryPath {
            directoryURL = URL(fileURLWithPath: configuredPath)
        } else {
            directoryURL = URL(
                fileURLWithPath: fileManager.currentDirectoryPath
            )
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "coreaudio-soak-reports",
                isDirectory: true
            )
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let timestamp = formatter.string(from: report.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let reportURL = directoryURL.appendingPathComponent(
            "cubilux-loopback-\(timestamp).json"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        return reportURL
    }

    static func attach(
        _ report: CoreAudioLoopbackLatencyReport,
        to testCase: XCTestCase
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(report),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "Cubilux hardware loopback latency report"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
