@testable import ScreamBar
import Combine
import Foundation
import os
import XCTest

private let coreAudioOperatorSoakLogger = Logger(
    subsystem: "com.screambar.tests",
    category: "CoreAudioOperatorSoak"
)

@MainActor
final class CoreAudioLongSoakOperatorTests: XCTestCase {
    func testOneHourFollowsCoreAudioDefaultOutputChanges() async throws {
        let configuration = CoreAudioLongSoakConfiguration()
        try configuration.requireOperatorOptIn()
        let initialSnapshot = try LegacyCoreAudioBackend().makeSnapshot(
            revision: 1
        )
        let input = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.inputName,
            in: initialSnapshot.inputDevices
        )
        let instructions = [
            "Leave Direct Routing on System Default output.",
            "Change the macOS default output at least \(configuration.minimumOutputChanges) times during the run.",
            "Return to the preferred default output before the run finishes.",
        ]
        let report = try await runOperatorScenario(
            scenario: .defaultOutputChanges,
            configuration: configuration,
            routingConfiguration: DirectRoutingConfiguration(
                inputSelection: .device(
                    uid: input.id,
                    lastKnownName: input.name
                ),
                outputSelection: .systemDefault,
                bufferSize: .automatic
            ),
            inputName: input.name,
            outputPreference: "System Default",
            instructions: instructions
        ) { tracker, finalState in
            var violations: [String] = []
            if tracker.effectiveOutputChangeCount
                < configuration.minimumOutputChanges {
                violations.append(
                    "observed \(tracker.effectiveOutputChangeCount) effective output changes; expected at least \(configuration.minimumOutputChanges)"
                )
            }
            if case .running = finalState {
                // Expected final state.
            } else {
                violations.append(
                    "Direct Routing was not running at the end: \(finalState)"
                )
            }
            return violations
        }
        try publishAndAssert(report, configuration: configuration)
    }

    func testOneHourCubiluxDisconnectReconnect() async throws {
        let configuration = CoreAudioLongSoakConfiguration()
        try configuration.requireOperatorOptIn()
        let initialSnapshot = try LegacyCoreAudioBackend().makeSnapshot(
            revision: 1
        )
        let input = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.inputName,
            in: initialSnapshot.inputDevices
        )
        let output = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.outputName,
            in: initialSnapshot.outputDevices
        )
        let instructions = [
            "Disconnect \(input.name) after Direct Routing is stable.",
            "Wait for Direct Routing to report that the input is unavailable.",
            "Reconnect \(input.name) and leave it connected through the end of the run.",
        ]
        let report = try await runOperatorScenario(
            scenario: .inputDisconnectReconnect,
            configuration: configuration,
            routingConfiguration: DirectRoutingConfiguration(
                inputSelection: .device(
                    uid: input.id,
                    lastKnownName: input.name
                ),
                outputSelection: .device(
                    uid: output.id,
                    lastKnownName: output.name
                ),
                bufferSize: .automatic
            ),
            inputName: input.name,
            outputPreference: output.name,
            instructions: instructions
        ) { tracker, finalState in
            var violations: [String] = []
            if !tracker.sawInputUnavailable {
                violations.append("the selected input never became unavailable")
            }
            if !tracker.sawInputRecovery {
                violations.append("the selected input did not recover after reconnect")
            }
            if case .running(let route) = finalState,
               route.input.id == input.id {
                // Expected final route.
            } else {
                violations.append(
                    "Direct Routing did not finish on the reconnected input: \(finalState)"
                )
            }
            return violations
        }
        try publishAndAssert(report, configuration: configuration)
    }

    func testOneHourInputRateCyclesFrom48KHzAndBack() async throws {
        let configuration = CoreAudioLongSoakConfiguration()
        try configuration.requireOperatorOptIn()
        let initialSnapshot = try LegacyCoreAudioBackend().makeSnapshot(
            revision: 1
        )
        let input = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.inputName,
            in: initialSnapshot.inputDevices
        )
        let output = try CoreAudioLongSoakDeviceResolver.find(
            named: configuration.outputName,
            in: initialSnapshot.outputDevices
        )
        guard sampleRatesMatch(input.currentNominalSampleRate, 48_000) else {
            throw XCTSkip(
                "The selected input must start at 48 kHz; current rate is \(input.currentNominalSampleRate) Hz"
            )
        }
        let instructions = [
            "Start with \(input.name) at 48 kHz.",
            "Make the input leave its initial 48-kHz state after the route is stable, either by selecting another supported nominal rate or by temporarily removing its digital lock.",
            "Return it to 48 kHz and leave Direct Routing running through the end.",
        ]
        let report = try await runOperatorScenario(
            scenario: .sampleRateCycle,
            configuration: configuration,
            routingConfiguration: DirectRoutingConfiguration(
                inputSelection: .device(
                    uid: input.id,
                    lastKnownName: input.name
                ),
                outputSelection: .device(
                    uid: output.id,
                    lastKnownName: output.name
                ),
                bufferSize: .automatic
            ),
            inputName: input.name,
            outputPreference: output.name,
            instructions: instructions
        ) { tracker, finalState in
            var violations: [String] = []
            if !tracker.sawInitial48KHz {
                violations.append("the initial running route was not observed at 48 kHz")
            }
            if !tracker.sawStateAwayFromInitial48KHz {
                violations.append(
                    "the input never left its initial 48-kHz state"
                )
            }
            if !tracker.sawReturnTo48KHz {
                violations.append("the running route did not return to 48 kHz")
            }
            if case .running = finalState {
                // Expected final state.
            } else {
                violations.append(
                    "Direct Routing was not running at the end: \(finalState)"
                )
            }
            return violations
        }
        try publishAndAssert(report, configuration: configuration)
    }

    private func runOperatorScenario(
        scenario: CoreAudioLongSoakScenario,
        configuration: CoreAudioLongSoakConfiguration,
        routingConfiguration: DirectRoutingConfiguration,
        inputName: String,
        outputPreference: String,
        instructions: [String],
        validate: (
            CoreAudioLongSoakRouteTracker,
            AudioRoutingState
        ) -> [String]
    ) async throws -> CoreAudioLongSoakReport {
        instructions.forEach {
            coreAudioOperatorSoakLogger.info("\($0, privacy: .public)")
        }
        let logStore = RollingLogStore()
        let backend = LegacyCoreAudioBackend()
        let telemetryCollector =
            CoreAudioLongSoakMultiSessionTelemetryCollector()
        backend.onAsyncSRCMetricsFinalized = { sessionID, metrics in
            telemetryCollector.recordFinalMetrics(
                sessionID: sessionID,
                metrics: metrics
            )
        }
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
        let tracker = CoreAudioLongSoakRouteTracker(
            startedAt: runTimer.startedAt
        )
        var finalizedSessionCountAtRouteStart =
            telemetryCollector.finalizedSessionCount
        let stateObservation = routingService.$state.sink { state in
            let hadUnavailableInput = tracker.sawInputUnavailable
            let hadLeftInitial48KHz = tracker.sawStateAwayFromInitial48KHz
            let hadReturnedTo48KHz = tracker.sawReturnTo48KHz
            tracker.observe(state)

            let observedExpectedInterruption =
                scenario == .inputDisconnectReconnect
                    && !hadUnavailableInput
                    && tracker.sawInputUnavailable
                || scenario == .sampleRateCycle
                    && !hadLeftInitial48KHz
                    && tracker.sawStateAwayFromInitial48KHz
                || scenario == .sampleRateCycle
                    && !hadReturnedTo48KHz
                    && tracker.sawReturnTo48KHz
            if observedExpectedInterruption {
                telemetryCollector
                    .markMostRecentlyFinalizedSessionAsExpectedInterruption(
                        ifFinalizedAfter: finalizedSessionCountAtRouteStart
                    )
                finalizedSessionCountAtRouteStart =
                    telemetryCollector.finalizedSessionCount
            }
            if case .running = state {
                finalizedSessionCountAtRouteStart =
                    telemetryCollector.finalizedSessionCount
            }
        }

        routingService.start(configuration: routingConfiguration)
        await routingService.waitForIdle()
        guard case .running = routingService.state else {
            let initialState = routingService.state
            stateObservation.cancel()
            let cleanupFailures = await routingService.shutdownAndWait()
            XCTAssertTrue(
                cleanupFailures.isEmpty,
                "Initial route cleanup failed: \(cleanupFailures)"
            )
            throw CoreAudioOperatorLongSoakError.initialRouteDidNotStart(
                initialState
            )
        }

        do {
            repeat {
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
                "Cancelled operator soak cleanup failed: \(cleanupFailures)"
            )
            throw error
        }

        let finalState = routingService.state
        var healthViolations = tracker.healthViolations
        healthViolations.append(contentsOf: validate(tracker, finalState))
        stateObservation.cancel()
        let cleanupFailures = await routingService.shutdownAndWait()
        healthViolations.append(contentsOf: cleanupFailures)
        let allowsExpectedInterruption = scenario == .inputDisconnectReconnect
            || scenario == .sampleRateCycle
        let sessionHealth = telemetryCollector.healthAssessment(
            policy: allowsExpectedInterruption
                ? .classifiedExpectedInterruptions
                : .allSessions
        )
        healthViolations.append(contentsOf: sessionHealth.violations)
        if allowsExpectedInterruption,
           telemetryCollector.finalizedSessionCount < 2 {
            healthViolations.append(
                "expected an interrupted and a recovered asynchronous-SRC session; finalized \(telemetryCollector.finalizedSessionCount)"
            )
        }
        let telemetry = telemetryCollector.makeSummary(
            latencyMinimumMilliseconds: tracker.latencyMinimumMilliseconds,
            latencyMaximumMilliseconds: tracker.latencyMaximumMilliseconds
        )

        return CoreAudioLongSoakReportWriter.makeReport(
            scenario: scenario,
            startedAt: startedAt,
            requestedDurationSeconds: configuration.durationSeconds,
            observedDurationSeconds: runTimer.elapsedSeconds,
            inputName: inputName,
            outputPreference: outputPreference,
            phases: tracker.phases,
            routeObservationCount: tracker.observationCount,
            pipelineRebuildCount: tracker.pipelineRebuildCount,
            effectiveOutputChangeCount: tracker.effectiveOutputChangeCount,
            effectiveSampleRateChangeCount:
                tracker.effectiveSampleRateChangeCount,
            stateEstimatedLatencyMinimumMilliseconds:
                tracker.latencyMinimumMilliseconds,
            stateEstimatedLatencyMaximumMilliseconds:
                tracker.latencyMaximumMilliseconds,
            stateConfiguredLatencyCeilingMaximumMilliseconds:
                tracker.latencyCeilingMaximumMilliseconds,
            telemetry: telemetry,
            healthViolations: Array(Set(healthViolations)).sorted(),
            sessionHealthDiagnostics: sessionHealth.diagnostics,
            operatorInstructions: instructions,
            limitations: [
                "Real-time telemetry is aggregated only for asynchronous-SRC sessions. Native common-rate sessions do not own the SRC callback context and therefore do not contribute FIFO or ratio statistics.",
            ]
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
        XCTAssertTrue(
            report.healthViolations.isEmpty,
            report.healthViolations.joined(separator: "; ")
        )
    }

    private func sampleRatesMatch(_ first: Double, _ second: Double) -> Bool {
        abs(first - second) <= 0.5
    }
}

private enum CoreAudioOperatorLongSoakError: LocalizedError {
    case initialRouteDidNotStart(AudioRoutingState)

    var errorDescription: String? {
        switch self {
        case .initialRouteDidNotStart(let state):
            return "The initial Direct Routing route did not start: \(state)"
        }
    }
}
