@testable import ScreamBar
import Combine
import Foundation
import os
import XCTest

private let asyncSRCLongSoakLogger = Logger(
    subsystem: "com.screambar.tests",
    category: "AsyncSRCLongSoak"
)

@MainActor
final class CoreAudioLongSoakAsyncSRCTests: XCTestCase {
    func testOneHourNormalConvertedRoute() async throws {
        let configuration = CoreAudioLongSoakConfiguration()
        try configuration.requireHardwareOptIn()
        let report = try await runFixedConvertedRoute(
            scenario: .normal,
            configuration: configuration,
            phaseSchedule: [
                ScheduledPhase(name: "steady-state", startFraction: 0),
            ]
        )
        try publishAndAssert(report, configuration: configuration)
    }

    func testOneHourSilenceThenResumeConvertedRoute() async throws {
        let configuration = CoreAudioLongSoakConfiguration()
        try configuration.requireOperatorOptIn()
        let report = try await runFixedConvertedRoute(
            scenario: .silenceAndResume,
            configuration: configuration,
            phaseSchedule: [
                ScheduledPhase(name: "audible-reference", startFraction: 0),
                ScheduledPhase(
                    name: "operator-mutes-source",
                    startFraction: 0.10
                ),
                ScheduledPhase(
                    name: "operator-resumes-source",
                    startFraction: 0.80
                ),
            ],
            operatorInstructions: [
                "Keep an audible reference signal active for the first 10% of the run.",
                "Make the physical input silent from 10% through 80% of the run.",
                "Resume the same reference signal for the final 20% of the run.",
            ],
            limitations: [
                "The current real-time telemetry measures transport health, not signal amplitude. The operator must confirm that the requested silence and resumed signal occurred.",
            ]
        )
        try publishAndAssert(report, configuration: configuration)
    }

    func testOneHourConvertedRouteUnderHighCPULoad() async throws {
        let configuration = CoreAudioLongSoakConfiguration()
        try configuration.requireHardwareOptIn()
        let cpuLoad = CoreAudioLongSoakCPULoad()
        asyncSRCLongSoakLogger.info(
            "Starting \(configuration.cpuWorkerCount) CPU load workers"
        )
        cpuLoad.start(workerCount: configuration.cpuWorkerCount)
        defer {
            cpuLoad.stop()
            asyncSRCLongSoakLogger.info("CPU load workers stopped")
        }

        let report = try await runFixedConvertedRoute(
            scenario: .highCPULoad,
            configuration: configuration,
            phaseSchedule: [
                ScheduledPhase(name: "high-cpu-load", startFraction: 0),
            ]
        )
        try publishAndAssert(report, configuration: configuration)
    }

    private func runFixedConvertedRoute(
        scenario: CoreAudioLongSoakScenario,
        configuration: CoreAudioLongSoakConfiguration,
        phaseSchedule: [ScheduledPhase],
        operatorInstructions: [String] = [],
        limitations: [String] = []
    ) async throws -> CoreAudioLongSoakReport {
        let backend = LegacyCoreAudioBackend()
        let initialSnapshot = try backend.makeSnapshot(revision: 1)
        let input = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.inputName,
            in: initialSnapshot.inputDevices
        )
        let output = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.outputName,
            in: initialSnapshot.outputDevices
        )
        let telemetryCollector =
            CoreAudioLongSoakMultiSessionTelemetryCollector()
        backend.onAsyncSRCMetricsFinalized = { sessionID, metrics in
            telemetryCollector.recordFinalMetrics(
                sessionID: sessionID,
                metrics: metrics
            )
        }
        let logStore = RollingLogStore()
        let deviceService = CoreAudioDeviceService(
            logStore: logStore,
            backend: backend
        )
        let routingService = DirectAudioRoutingService(
            logStore: logStore,
            deviceService: deviceService,
            permissionService: CoreAudioLongSoakAudioInputPermission()
        )
        let startedAt = Date()
        let runTimer = CoreAudioLongSoakMonotonicTimer(
            durationSeconds: configuration.durationSeconds
        )
        let routeTracker = CoreAudioLongSoakRouteTracker(
            startedAt: runTimer.startedAt
        )
        let stateObservation = routingService.$state.sink {
            routeTracker.observe($0)
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
        guard case .running(let initialRoute) = routingService.state else {
            let initialState = routingService.state
            stateObservation.cancel()
            let cleanupFailures = await routingService.shutdownAndWait()
            XCTAssertTrue(
                cleanupFailures.isEmpty,
                "Initial route cleanup failed: \(cleanupFailures)"
            )
            throw CoreAudioLongSoakTestError.initialRouteDidNotStart(
                initialState
            )
        }
        guard initialRoute.usesSampleRateConversion else {
            stateObservation.cancel()
            let cleanupFailures = await routingService.shutdownAndWait()
            XCTAssertTrue(
                cleanupFailures.isEmpty,
                "Common-rate route cleanup failed: \(cleanupFailures)"
            )
            throw XCTSkip(
                "Selected devices expose a common nominal sample rate; this soak specifically validates asynchronous SRC"
            )
        }

        var observedPhases: [CoreAudioLongSoakPhase] = []
        var activePhaseIndex: Int?
        do {
            repeat {
                let elapsedSeconds = runTimer.elapsedSeconds
                if let phaseIndex = phaseSchedule.lastIndex(where: {
                    elapsedSeconds
                        >= configuration.durationSeconds * $0.startFraction
                }), phaseIndex != activePhaseIndex {
                    activePhaseIndex = phaseIndex
                    let phase = CoreAudioLongSoakPhase(
                        name: phaseSchedule[phaseIndex].name,
                        startedAfterSeconds: elapsedSeconds
                    )
                    observedPhases.append(phase)
                    asyncSRCLongSoakLogger.info(
                        "CoreAudio soak phase: \(phase.name, privacy: .public)"
                    )
                }

                guard !runTimer.hasReachedDeadline else { break }
                try await runTimer.sleepUntilNextPoll(
                    maximumNanoseconds:
                        configuration.pollingIntervalNanoseconds
                )
                await routingService.waitForIdle()
            } while true
        } catch {
            stateObservation.cancel()
            let cleanupFailures = await routingService.shutdownAndWait()
            XCTAssertTrue(
                cleanupFailures.isEmpty,
                "Cancelled automated soak cleanup failed: \(cleanupFailures)"
            )
            throw error
        }

        let finalState = routingService.state
        stateObservation.cancel()
        let cleanupFailures = await routingService.shutdownAndWait()
        var healthViolations = routeTracker.healthViolations
        healthViolations.append(contentsOf: cleanupFailures)
        healthViolations.append(contentsOf: telemetryCollector.healthViolations)
        if case .running = finalState {
            // Expected final state.
        } else {
            healthViolations.append(
                "Direct Routing was not running at the end: \(finalState)"
            )
        }
        let telemetry = telemetryCollector.makeSummary(
            latencyMinimumMilliseconds:
                routeTracker.latencyMinimumMilliseconds,
            latencyMaximumMilliseconds:
                routeTracker.latencyMaximumMilliseconds
        )
        if telemetry?.capturedFrames == 0 {
            healthViolations.append("no input frames were captured")
        }
        if telemetry?.renderedFrames == 0 {
            healthViolations.append("no output frames were rendered")
        }
        if telemetry == nil {
            healthViolations.append(
                "no finalized asynchronous-SRC telemetry was captured"
            )
        }
        if telemetryCollector.finalizedSessionCount != 1 {
            healthViolations.append(
                "expected one stable asynchronous-SRC session, finalized \(telemetryCollector.finalizedSessionCount)"
            )
        }
        if routeTracker.pipelineRebuildCount != 0 {
            healthViolations.append(
                "the stable-route soak rebuilt the pipeline \(routeTracker.pipelineRebuildCount) times"
            )
        }

        return CoreAudioLongSoakReportWriter.makeReport(
            scenario: scenario,
            startedAt: startedAt,
            requestedDurationSeconds: configuration.durationSeconds,
            observedDurationSeconds: runTimer.elapsedSeconds,
            inputName: input.name,
            outputPreference: output.name,
            phases: (observedPhases + routeTracker.phases).sorted {
                $0.startedAfterSeconds < $1.startedAfterSeconds
            },
            routeObservationCount: routeTracker.observationCount,
            pipelineRebuildCount: routeTracker.pipelineRebuildCount,
            effectiveOutputChangeCount:
                routeTracker.effectiveOutputChangeCount,
            effectiveSampleRateChangeCount:
                routeTracker.effectiveSampleRateChangeCount,
            stateEstimatedLatencyMinimumMilliseconds:
                routeTracker.latencyMinimumMilliseconds,
            stateEstimatedLatencyMaximumMilliseconds:
                routeTracker.latencyMaximumMilliseconds,
            stateConfiguredLatencyCeilingMaximumMilliseconds:
                routeTracker.latencyCeilingMaximumMilliseconds,
            telemetry: telemetry,
            healthViolations: Array(Set(healthViolations)).sorted(),
            operatorInstructions: operatorInstructions,
            limitations: limitations
        )
    }

    private func publishAndAssert(
        _ report: CoreAudioLongSoakReport,
        configuration: CoreAudioLongSoakConfiguration
    ) throws {
        _ = try CoreAudioLongSoakReportWriter.write(
            report,
            configuration: configuration
        )
        try CoreAudioLongSoakReportWriter.attach(report, to: self)
        XCTAssertGreaterThan(
            report.telemetry?.finalizedAsyncSRCSessionCount ?? 0,
            0,
            "The soak report contains no telemetry samples"
        )
        XCTAssertTrue(
            report.healthViolations.isEmpty,
            report.healthViolations.joined(separator: "; ")
        )
    }

}

private struct ScheduledPhase {
    let name: String
    let startFraction: Double

    init(name: String, startFraction: Double) {
        precondition((0...1).contains(startFraction))
        self.name = name
        self.startFraction = startFraction
    }
}

private enum CoreAudioLongSoakTestError: LocalizedError {
    case initialRouteDidNotStart(AudioRoutingState)

    var errorDescription: String? {
        switch self {
        case .initialRouteDidNotStart(let state):
            return "The initial Direct Routing route did not start: \(state)"
        }
    }
}
