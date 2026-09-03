@testable import ScreamBar
import Foundation
import os
import XCTest

private let coreAudioLongSoakLogger = Logger(
    subsystem: "com.screambar.tests",
    category: "CoreAudioLongSoak"
)

@MainActor
final class CoreAudioLongSoakAudioInputPermission:
    AudioInputPermissionServicing {
    func requestPermissionIfNeeded() async throws {}
}

enum CoreAudioLongSoakDeviceResolver {
    static func find(
        named requestedName: String,
        in devices: [AudioDeviceDescriptor]
    ) throws -> AudioDeviceDescriptor {
        guard let device = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains(requestedName)
        }) else {
            throw XCTSkip(
                "CoreAudio device matching '\(requestedName)' is unavailable"
            )
        }
        return device
    }
}

enum CoreAudioLongSoakScenario: String, Codable {
    case normal
    case silenceAndResume = "silence-and-resume"
    case highCPULoad = "high-cpu-load"
    case defaultOutputChanges = "default-output-changes"
    case inputDisconnectReconnect = "input-disconnect-reconnect"
    case sampleRateCycle = "sample-rate-cycle"
}

struct CoreAudioLongSoakPhase: Codable, Equatable {
    let name: String
    let startedAfterSeconds: Double
}

struct CoreAudioLongSoakTelemetry: Codable, Equatable {
    var finalizedAsyncSRCSessionCount = 0
    var fifoFillSampleCount: UInt64 = 0
    var capturedFrames: UInt64 = 0
    var renderedFrames: UInt64 = 0
    var underrunCount: UInt64 = 0
    var latencyCeilingUnderrunCount: UInt64 = 0
    var overrunCount: UInt64 = 0
    var latencyCeilingOverrunCount: UInt64 = 0
    var resynchronizationCount: UInt64 = 0
    var droppedInputFrames: UInt64 = 0
    var primingSilenceFrames: UInt64 = 0
    var startupTrimCount: UInt64 = 0
    var startupTrimmedFrames: UInt64 = 0
    var fifoMinimumFillFrames: UInt32?
    var fifoMaximumFillFrames: UInt32?
    var fifoMeanFillFrames: Double?
    var srcPlaybackRateAdjustmentCount: UInt64 = 0
    var srcPlaybackRateMinimum: Double?
    var srcPlaybackRateMaximum: Double?
    var estimatedLatencyMinimumMilliseconds: Double?
    var estimatedLatencyMaximumMilliseconds: Double?
    var inputCallbackDeadlineMissCount: UInt64 = 0
    var outputCallbackDeadlineMissCount: UInt64 = 0
    var maximumInputCallbackGapMilliseconds: Double = 0
    var maximumOutputCallbackGapMilliseconds: Double = 0
    var maximumInputCallbackExecutionMicroseconds: Double = 0
    var maximumOutputCallbackExecutionMicroseconds: Double = 0
    var inputRenderErrorCount: UInt64 = 0
    var outputRenderErrorCount: UInt64 = 0
    var rateParameterErrorCount: UInt64 = 0
    var inputCallbackFrameLimitExceededCount: UInt64 = 0
    var outputCallbackFrameLimitExceededCount: UInt64 = 0
    var telemetrySaturated = false
}

struct CoreAudioLongSoakReport: Codable, Equatable {
    let schemaVersion: Int
    let scenario: CoreAudioLongSoakScenario
    let startedAt: Date
    let finishedAt: Date
    let requestedDurationSeconds: Double
    let observedDurationSeconds: Double
    let inputName: String
    let outputPreference: String
    let phases: [CoreAudioLongSoakPhase]
    let routeObservationCount: Int
    let pipelineRebuildCount: Int
    let effectiveOutputChangeCount: Int
    let effectiveSampleRateChangeCount: Int
    let stateEstimatedLatencyMinimumMilliseconds: Double?
    let stateEstimatedLatencyMaximumMilliseconds: Double?
    let stateConfiguredLatencyCeilingMaximumMilliseconds: Double?
    let telemetry: CoreAudioLongSoakTelemetry?
    let healthViolations: [String]
    let sessionHealthDiagnostics: [String]
    let operatorInstructions: [String]
    let limitations: [String]
}

struct CoreAudioLongSoakConfiguration {
    static let hardwareOptInKey =
        "SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS"
    static let operatorOptInKey =
        "SCREAMBAR_RUN_COREAUDIO_OPERATOR_SOAK_TESTS"
    static let durationKey = "SCREAMBAR_ASYNC_SRC_SOAK_SECONDS"
    static let pollingIntervalKey =
        "SCREAMBAR_ASYNC_SRC_SOAK_POLL_MILLISECONDS"
    static let inputNameKey = "SCREAMBAR_ASYNC_SRC_INPUT_NAME"
    static let outputNameKey = "SCREAMBAR_ASYNC_SRC_OUTPUT_NAME"
    static let reportDirectoryKey =
        "SCREAMBAR_ASYNC_SRC_SOAK_REPORT_DIRECTORY"
    static let cpuWorkerCountKey =
        "SCREAMBAR_ASYNC_SRC_CPU_LOAD_WORKERS"
    static let minimumOutputChangesKey =
        "SCREAMBAR_ASYNC_SRC_MINIMUM_OUTPUT_CHANGES"

    static let defaultDurationSeconds = 3_600.0
    static let defaultPollingIntervalMilliseconds = 500.0
    static let defaultInputName = "Cubilux SPDIF Receiver"
    static let defaultOutputName = "Bose QC 45"
    static let defaultMinimumOutputChanges = 2

    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var durationSeconds: Double {
        positiveDouble(for: Self.durationKey)
            ?? Self.defaultDurationSeconds
    }

    var pollingIntervalNanoseconds: UInt64 {
        let milliseconds = positiveDouble(for: Self.pollingIntervalKey)
            ?? Self.defaultPollingIntervalMilliseconds
        return UInt64(milliseconds * 1_000_000)
    }

    var inputName: String {
        environment[Self.inputNameKey] ?? Self.defaultInputName
    }

    var outputName: String {
        environment[Self.outputNameKey] ?? Self.defaultOutputName
    }

    var cpuWorkerCount: Int {
        if let rawValue = environment[Self.cpuWorkerCountKey],
           let configuredValue = Int(rawValue),
           configuredValue > 0 {
            return min(
                configuredValue,
                ProcessInfo.processInfo.activeProcessorCount
            )
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    var minimumOutputChanges: Int {
        if let rawValue = environment[Self.minimumOutputChangesKey],
           let configuredValue = Int(rawValue),
           configuredValue > 0 {
            return configuredValue
        }
        return Self.defaultMinimumOutputChanges
    }

    func requireHardwareOptIn() throws {
        guard environment[Self.hardwareOptInKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.hardwareOptInKey)=1 to run one-hour CoreAudio soak tests"
            )
        }
    }

    func requireOperatorOptIn() throws {
        try requireHardwareOptIn()
        guard environment[Self.operatorOptInKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.operatorOptInKey)=1 only when an operator is present to perform the requested hardware actions"
            )
        }
    }

    private func positiveDouble(for key: String) -> Double? {
        guard let rawValue = environment[key],
              let value = Double(rawValue),
              value.isFinite,
              value > 0 else {
            return nil
        }
        return value
    }
}

struct CoreAudioLongSoakMonotonicTimer {
    private static let nanosecondsPerSecond = 1_000_000_000.0

    private let clock = ContinuousClock()
    let startedAt: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant

    init(durationSeconds: Double) {
        precondition(durationSeconds.isFinite && durationSeconds > 0)
        startedAt = clock.now
        let durationNanoseconds = Int64(
            min(
                durationSeconds * Self.nanosecondsPerSecond,
                Double(Int64.max)
            )
        )
        deadline = startedAt.advanced(
            by: .nanoseconds(durationNanoseconds)
        )
    }

    var hasReachedDeadline: Bool {
        clock.now >= deadline
    }

    var elapsedSeconds: Double {
        Self.seconds(from: startedAt.duration(to: clock.now))
    }

    func sleepUntilNextPoll(maximumNanoseconds: UInt64) async throws {
        let now = clock.now
        guard now < deadline else { return }
        let boundedNanoseconds = Int64(
            min(maximumNanoseconds, UInt64(Int64.max))
        )
        let pollingDeadline = now.advanced(
            by: .nanoseconds(boundedNanoseconds)
        )
        try await clock.sleep(
            until: Swift.min(deadline, pollingDeadline),
            tolerance: nil
        )
    }

    static func seconds(
        from duration: Duration
    ) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum CoreAudioLongSoakSessionHealthPolicy {
    case allSessions
    case classifiedExpectedInterruptions
}

struct CoreAudioLongSoakSessionHealthAssessment: Equatable {
    let violations: [String]
    let diagnostics: [String]
}

@MainActor
final class CoreAudioLongSoakMultiSessionTelemetryCollector {
    private(set) var finalizedSessionCount = 0

    private var telemetry = CoreAudioLongSoakTelemetry()
    private var fifoFillFrameSum: UInt64 = 0
    private struct SessionHealthRecord {
        let sessionID: UUID
        let violations: [String]
        var isExpectedInterruption: Bool
    }

    private var sessionHealthRecords: [SessionHealthRecord] = []

    func recordFinalMetrics(sessionID: UUID, metrics: AsyncSRCMetrics) {
        finalizedSessionCount += 1
        telemetry.finalizedAsyncSRCSessionCount += 1
        telemetry.fifoFillSampleCount += metrics.fifoFillSampleCount
        fifoFillFrameSum += metrics.fifoFillFrameSum
        telemetry.capturedFrames += metrics.capturedFrames
        telemetry.renderedFrames += metrics.renderedFrames
        telemetry.underrunCount += metrics.underrunCount
        telemetry.latencyCeilingUnderrunCount +=
            metrics.latencyCeilingUnderrunCount
        telemetry.overrunCount += metrics.overflowCount
        telemetry.latencyCeilingOverrunCount +=
            metrics.latencyCeilingOverflowCount
        telemetry.resynchronizationCount += metrics.resynchronizationCount
        telemetry.droppedInputFrames += metrics.droppedInputFrames
        telemetry.primingSilenceFrames += metrics.primingSilenceFrames
        telemetry.startupTrimCount += metrics.startupTrimCount
        telemetry.startupTrimmedFrames += metrics.startupTrimmedFrames
        telemetry.srcPlaybackRateAdjustmentCount +=
            metrics.playbackRateAdjustmentCount
        telemetry.inputCallbackDeadlineMissCount +=
            metrics.inputCallbackDeadlineMissCount
        telemetry.outputCallbackDeadlineMissCount +=
            metrics.outputCallbackDeadlineMissCount
        telemetry.maximumInputCallbackGapMilliseconds = max(
            telemetry.maximumInputCallbackGapMilliseconds,
            Double(metrics.maximumInputCallbackGapNanoseconds) / 1_000_000
        )
        telemetry.maximumOutputCallbackGapMilliseconds = max(
            telemetry.maximumOutputCallbackGapMilliseconds,
            Double(metrics.maximumOutputCallbackGapNanoseconds) / 1_000_000
        )
        telemetry.maximumInputCallbackExecutionMicroseconds = max(
            telemetry.maximumInputCallbackExecutionMicroseconds,
            Double(metrics.maximumInputCallbackExecutionNanoseconds) / 1_000
        )
        telemetry.maximumOutputCallbackExecutionMicroseconds = max(
            telemetry.maximumOutputCallbackExecutionMicroseconds,
            Double(metrics.maximumOutputCallbackExecutionNanoseconds) / 1_000
        )
        telemetry.inputRenderErrorCount += metrics.inputRenderErrorCount
        telemetry.outputRenderErrorCount += metrics.outputRenderErrorCount
        telemetry.rateParameterErrorCount += metrics.rateParameterErrorCount
        telemetry.inputCallbackFrameLimitExceededCount +=
            metrics.inputCallbackFrameLimitExceededCount
        telemetry.outputCallbackFrameLimitExceededCount +=
            metrics.outputCallbackFrameLimitExceededCount
        telemetry.telemetrySaturated = telemetry.telemetrySaturated
            || metrics.telemetrySaturated

        if metrics.fifoFillSampleCount > 0 {
            telemetry.fifoMinimumFillFrames = minimum(
                telemetry.fifoMinimumFillFrames,
                metrics.minimumFIFOFillFrames
            )
            telemetry.fifoMaximumFillFrames = maximum(
                telemetry.fifoMaximumFillFrames,
                metrics.maximumFIFOFillFrames
            )
        }
        if let minimumPlaybackRate = metrics.minimumPlaybackRate {
            telemetry.srcPlaybackRateMinimum = minimum(
                telemetry.srcPlaybackRateMinimum,
                minimumPlaybackRate
            )
        }
        if let maximumPlaybackRate = metrics.maximumPlaybackRate {
            telemetry.srcPlaybackRateMaximum = maximum(
                telemetry.srcPlaybackRateMaximum,
                maximumPlaybackRate
            )
        }
        sessionHealthRecords.append(
            SessionHealthRecord(
                sessionID: sessionID,
                violations: finalMetricViolations(
                    sessionID: sessionID,
                    metrics: metrics
                ),
                isExpectedInterruption: false
            )
        )
    }

    @discardableResult
    func markMostRecentlyFinalizedSessionAsExpectedInterruption(
        ifFinalizedAfter previousFinalizedSessionCount: Int
    ) -> Bool {
        guard finalizedSessionCount > previousFinalizedSessionCount,
              let recordIndex = sessionHealthRecords.indices.last,
              !sessionHealthRecords[recordIndex].isExpectedInterruption else {
            return false
        }
        sessionHealthRecords[recordIndex].isExpectedInterruption = true
        return true
    }

    var healthViolations: [String] {
        healthAssessment(policy: .allSessions).violations
    }

    func healthAssessment(
        policy: CoreAudioLongSoakSessionHealthPolicy
    ) -> CoreAudioLongSoakSessionHealthAssessment {
        switch policy {
        case .allSessions:
            return CoreAudioLongSoakSessionHealthAssessment(
                violations: sessionHealthRecords.flatMap(\.violations),
                diagnostics: []
            )
        case .classifiedExpectedInterruptions:
            guard let latestRecord = sessionHealthRecords.last else {
                return CoreAudioLongSoakSessionHealthAssessment(
                    violations: [
                        "no finalized asynchronous-SRC session was available after recovery",
                    ],
                    diagnostics: []
                )
            }
            let expectedRecords = sessionHealthRecords.filter(
                \.isExpectedInterruption
            )
            var violations = sessionHealthRecords
                .filter { !$0.isExpectedInterruption }
                .flatMap(\.violations)
            guard !expectedRecords.isEmpty else {
                violations.append(
                    "no asynchronous-SRC session was classified as the expected interruption"
                )
                return CoreAudioLongSoakSessionHealthAssessment(
                    violations: violations,
                    diagnostics: []
                )
            }
            if latestRecord.isExpectedInterruption {
                violations.append(
                    "no finalized asynchronous-SRC session was available after the expected interruption"
                )
            }
            let diagnostics = expectedRecords.flatMap { record in
                if record.violations.isEmpty {
                    return [
                        "session \(record.sessionID.uuidString) ended during the expected interruption without a transport-health event",
                    ]
                }
                return record.violations.map {
                    "expected interruption: \($0)"
                }
            }
            return CoreAudioLongSoakSessionHealthAssessment(
                violations: violations,
                diagnostics: diagnostics
            )
        }
    }

    func makeSummary(
        latencyMinimumMilliseconds: Double?,
        latencyMaximumMilliseconds: Double?
    ) -> CoreAudioLongSoakTelemetry? {
        guard finalizedSessionCount > 0 else { return nil }
        telemetry.fifoMeanFillFrames = telemetry.fifoFillSampleCount == 0
            ? nil
            : Double(fifoFillFrameSum)
                / Double(telemetry.fifoFillSampleCount)
        telemetry.estimatedLatencyMinimumMilliseconds =
            latencyMinimumMilliseconds
        telemetry.estimatedLatencyMaximumMilliseconds =
            latencyMaximumMilliseconds
        return telemetry
    }

    private func finalMetricViolations(
        sessionID: UUID,
        metrics: AsyncSRCMetrics
    ) -> [String] {
        let prefix = "session \(sessionID.uuidString)"
        var violations: [String] = []
        appendIfPositive(
            metrics.underrunCount,
            name: "FIFO underruns",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.latencyCeilingUnderrunCount,
            name: "FIFO underruns at latency ceiling",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.overflowCount,
            name: "FIFO overruns",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.resynchronizationCount,
            name: "FIFO resynchronizations",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.droppedInputFrames,
            name: "dropped input frames",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.inputCallbackDeadlineMissCount,
            name: "input callback deadline misses",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.outputCallbackDeadlineMissCount,
            name: "output callback deadline misses",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.inputRenderErrorCount,
            name: "input render errors",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.outputRenderErrorCount,
            name: "output render errors",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.rateParameterErrorCount,
            name: "SRC rate parameter errors",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.latencyCeilingOverflowCount,
            name: "latency-ceiling FIFO overruns",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.inputCallbackFrameLimitExceededCount,
            name: "input callback frame-limit violations",
            prefix: prefix,
            to: &violations
        )
        appendIfPositive(
            metrics.outputCallbackFrameLimitExceededCount,
            name: "output callback frame-limit violations",
            prefix: prefix,
            to: &violations
        )
        if metrics.telemetrySaturated {
            violations.append("\(prefix) real-time telemetry saturated")
        }
        return violations
    }

    private func appendIfPositive(
        _ value: UInt64,
        name: String,
        prefix: String,
        to violations: inout [String]
    ) {
        guard value > 0 else { return }
        violations.append("\(prefix) \(name): \(value)")
    }

    private func minimum<T: Comparable>(_ current: T?, _ value: T) -> T {
        current.map { Swift.min($0, value) } ?? value
    }

    private func maximum<T: Comparable>(_ current: T?, _ value: T) -> T {
        current.map { Swift.max($0, value) } ?? value
    }
}

enum CoreAudioLongSoakReportWriter {
    private static let schemaVersion = 1

    static func makeReport(
        scenario: CoreAudioLongSoakScenario,
        startedAt: Date,
        requestedDurationSeconds: Double,
        observedDurationSeconds: Double? = nil,
        inputName: String,
        outputPreference: String,
        phases: [CoreAudioLongSoakPhase],
        routeObservationCount: Int = 0,
        pipelineRebuildCount: Int,
        effectiveOutputChangeCount: Int,
        effectiveSampleRateChangeCount: Int,
        stateEstimatedLatencyMinimumMilliseconds: Double? = nil,
        stateEstimatedLatencyMaximumMilliseconds: Double? = nil,
        stateConfiguredLatencyCeilingMaximumMilliseconds: Double? = nil,
        telemetry: CoreAudioLongSoakTelemetry?,
        healthViolations: [String],
        sessionHealthDiagnostics: [String] = [],
        operatorInstructions: [String] = [],
        limitations: [String] = []
    ) -> CoreAudioLongSoakReport {
        let finishedAt = Date()
        return CoreAudioLongSoakReport(
            schemaVersion: schemaVersion,
            scenario: scenario,
            startedAt: startedAt,
            finishedAt: finishedAt,
            requestedDurationSeconds: requestedDurationSeconds,
            observedDurationSeconds: observedDurationSeconds
                ?? finishedAt.timeIntervalSince(startedAt),
            inputName: inputName,
            outputPreference: outputPreference,
            phases: phases,
            routeObservationCount: routeObservationCount,
            pipelineRebuildCount: pipelineRebuildCount,
            effectiveOutputChangeCount: effectiveOutputChangeCount,
            effectiveSampleRateChangeCount: effectiveSampleRateChangeCount,
            stateEstimatedLatencyMinimumMilliseconds:
                stateEstimatedLatencyMinimumMilliseconds,
            stateEstimatedLatencyMaximumMilliseconds:
                stateEstimatedLatencyMaximumMilliseconds,
            stateConfiguredLatencyCeilingMaximumMilliseconds:
                stateConfiguredLatencyCeilingMaximumMilliseconds,
            telemetry: telemetry,
            healthViolations: healthViolations,
            sessionHealthDiagnostics: sessionHealthDiagnostics,
            operatorInstructions: operatorInstructions,
            limitations: limitations
        )
    }

    @discardableResult
    static func write(
        _ report: CoreAudioLongSoakReport,
        configuration: CoreAudioLongSoakConfiguration,
        fileManager: FileManager = .default
    ) throws -> URL {
        let repositoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let directoryURL: URL
        if let configuredPath = configuration.environment[
            CoreAudioLongSoakConfiguration.reportDirectoryKey
        ] {
            directoryURL = URL(fileURLWithPath: configuredPath)
        } else {
            directoryURL = repositoryURL
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
            "\(report.scenario.rawValue)-\(timestamp).json"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        coreAudioLongSoakLogger.info(
            "CoreAudio soak report written to \(reportURL.path, privacy: .public)"
        )
        return reportURL
    }

    static func attach(
        _ report: CoreAudioLongSoakReport,
        to testCase: XCTestCase
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)
        let attachment = XCTAttachment(
            data: reportData,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "CoreAudio \(report.scenario.rawValue) soak report"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}

final class CoreAudioLongSoakCPULoad {
    private static let batchIterationCount = 16_384

    private let condition = NSCondition()
    private let group = DispatchGroup()
    private var shouldStop = false
    private var workerChecksums: [Double] = []

    func start(workerCount: Int) {
        precondition(workerCount > 0)
        condition.lock()
        shouldStop = false
        workerChecksums.removeAll(keepingCapacity: true)
        condition.unlock()

        for workerIndex in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                runWorker(seed: Double(workerIndex + 1))
                group.leave()
            }
        }
    }

    func stop() {
        condition.lock()
        shouldStop = true
        condition.broadcast()
        condition.unlock()
        group.wait()
    }

    private func runWorker(seed: Double) {
        var checksum = seed
        while !isStopping {
            for iteration in 1...Self.batchIterationCount {
                let operand = Double(iteration) + seed
                checksum = (checksum * 1.000_000_119 + operand)
                    .truncatingRemainder(dividingBy: 1_000_003)
            }
        }
        condition.lock()
        workerChecksums.append(checksum)
        condition.unlock()
    }

    private var isStopping: Bool {
        condition.lock()
        defer { condition.unlock() }
        return shouldStop
    }
}

@MainActor
final class CoreAudioLongSoakRouteTracker {
    private static let sampleRateTolerance = 0.5

    private(set) var phases: [CoreAudioLongSoakPhase] = []
    private(set) var observationCount = 0
    private(set) var pipelineRebuildCount = 0
    private(set) var effectiveOutputChangeCount = 0
    private(set) var effectiveSampleRateChangeCount = 0
    private(set) var sawInputUnavailable = false
    private(set) var sawInputRecovery = false
    private(set) var sawInitial48KHz = false
    private(set) var sawNon48KHzAfterInitial = false
    private(set) var sawStateAwayFromInitial48KHz = false
    private(set) var sawReturnTo48KHz = false
    private(set) var healthViolations: [String] = []
    private(set) var latencyMinimumMilliseconds: Double?
    private(set) var latencyMaximumMilliseconds: Double?
    private(set) var latencyCeilingMaximumMilliseconds: Double?

    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var previousState: AudioRoutingState?
    private var lastRunningOutputUID: AudioDeviceUID?
    private var lastRunningInputSampleRate: Double?
    private var hasObservedRunningRoute = false

    init(startedAt: ContinuousClock.Instant = ContinuousClock().now) {
        self.startedAt = startedAt
    }

    func observe(_ state: AudioRoutingState) {
        observationCount += 1
        if case .reconfiguring = state,
           !isReconfiguring(previousState) {
            pipelineRebuildCount += 1
            recordPhase("pipeline-rebuild-\(pipelineRebuildCount)")
        } else if case .starting = state,
                  hasObservedRunningRoute,
                  !isStarting(previousState) {
            pipelineRebuildCount += 1
            recordPhase("pipeline-rebuild-\(pipelineRebuildCount)")
        }

        switch state {
        case .running(let route):
            observeRunningRoute(route)
            hasObservedRunningRoute = true
            if sawInputUnavailable {
                sawInputRecovery = true
            }
        case .waitingForInput:
            if !sawInputUnavailable {
                recordPhase("input-unavailable")
            }
            sawInputUnavailable = true
            if sawInitial48KHz {
                sawStateAwayFromInitial48KHz = true
            }
        case .failed(let error):
            healthViolations.append(
                "Direct Routing failed: \(error.localizedDescription)"
            )
        case .stopped, .starting, .reconfiguring, .waitingForOutput, .stopping:
            break
        }
        previousState = state
    }

    private func observeRunningRoute(_ route: EffectiveAudioRoute) {
        if let lastRunningOutputUID,
           lastRunningOutputUID != route.output.id {
            effectiveOutputChangeCount += 1
            recordPhase(
                "effective-output-\(effectiveOutputChangeCount)-\(route.output.name)"
            )
        }
        lastRunningOutputUID = route.output.id

        let inputSampleRate = route.inputNominalSampleRate
        if let lastRunningInputSampleRate,
           !sampleRatesMatch(lastRunningInputSampleRate, inputSampleRate) {
            effectiveSampleRateChangeCount += 1
            recordPhase(
                "input-rate-\(Int(inputSampleRate.rounded()))-hz"
            )
        }
        lastRunningInputSampleRate = inputSampleRate

        if sampleRatesMatch(inputSampleRate, 48_000) {
            if !sawInitial48KHz {
                sawInitial48KHz = true
                recordPhase("initial-48000-hz")
            } else if sawStateAwayFromInitial48KHz, !sawReturnTo48KHz {
                sawReturnTo48KHz = true
                recordPhase("returned-to-48000-hz")
            }
        } else if sawInitial48KHz, !sawNon48KHzAfterInitial {
            sawNon48KHzAfterInitial = true
            sawStateAwayFromInitial48KHz = true
            recordPhase("left-48000-hz")
        }

        if let estimatedSeconds = route.estimatedApplicationLatencySeconds {
            latencyMinimumMilliseconds = minimum(
                latencyMinimumMilliseconds,
                estimatedSeconds * 1_000
            )
            latencyMaximumMilliseconds = maximum(
                latencyMaximumMilliseconds,
                estimatedSeconds * 1_000
            )
        }
        if let maximumSeconds = route.maximumApplicationLatencySeconds {
            latencyCeilingMaximumMilliseconds = maximum(
                latencyCeilingMaximumMilliseconds,
                maximumSeconds * 1_000
            )
        }
    }

    private func recordPhase(_ name: String) {
        phases.append(
            CoreAudioLongSoakPhase(
                name: name,
                startedAfterSeconds: CoreAudioLongSoakMonotonicTimer.seconds(
                    from: startedAt.duration(to: clock.now)
                )
            )
        )
    }

    private func sampleRatesMatch(_ first: Double, _ second: Double) -> Bool {
        abs(first - second) <= Self.sampleRateTolerance
    }

    private func isReconfiguring(_ state: AudioRoutingState?) -> Bool {
        guard case .reconfiguring = state else { return false }
        return true
    }

    private func isStarting(_ state: AudioRoutingState?) -> Bool {
        guard case .starting = state else { return false }
        return true
    }

    private func minimum<T: Comparable>(_ current: T?, _ value: T) -> T {
        current.map { Swift.min($0, value) } ?? value
    }

    private func maximum<T: Comparable>(_ current: T?, _ value: T) -> T {
        current.map { Swift.max($0, value) } ?? value
    }
}
