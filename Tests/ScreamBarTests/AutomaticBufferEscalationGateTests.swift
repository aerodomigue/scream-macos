@testable import ScreamBar
import XCTest

final class AutomaticBufferEscalationGateTests: XCTestCase {
    func testStrictEscalatesOnFirstIncident() {
        var gate = AutomaticBufferEscalationGate()

        let evaluation = gate.evaluate(
            sensitivity: .strict,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 1,
            monotonicTime: 1
        )

        XCTAssertTrue(evaluation.shouldEscalate)
    }

    func testRelaxedToleratesThreeIncidentsAndEscalatesOnFourth() {
        var gate = AutomaticBufferEscalationGate()
        var cumulativeIncidentCount: UInt64 = 0

        for episodeCount in 1...3 {
            cumulativeIncidentCount += 1
            let evaluation = gate.evaluate(
                sensitivity: .relaxed,
                routeRequiresEscalation: true,
                cumulativeIncidentCount: cumulativeIncidentCount,
                monotonicTime: TimeInterval(episodeCount * 2)
            )
            XCTAssertFalse(evaluation.shouldEscalate)
            XCTAssertTrue(evaluation.didStartEpisode)
            XCTAssertEqual(evaluation.recentEpisodeCount, episodeCount)
            _ = gate.evaluate(
                sensitivity: .relaxed,
                routeRequiresEscalation: true,
                cumulativeIncidentCount: cumulativeIncidentCount,
                monotonicTime: TimeInterval(episodeCount * 2) + 0.5
            )
        }

        cumulativeIncidentCount += 1
        let fourthEvaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: cumulativeIncidentCount,
            monotonicTime: 8
        )

        XCTAssertTrue(fourthEvaluation.shouldEscalate)
        XCTAssertEqual(fourthEvaluation.recentEpisodeCount, 4)
    }

    func testRelaxedDoesNotCountTheSameCumulativeIncidentTwice() {
        var gate = AutomaticBufferEscalationGate()

        _ = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 1,
            monotonicTime: 1
        )
        let repeatedEvaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 1,
            monotonicTime: 2
        )

        XCTAssertFalse(repeatedEvaluation.shouldEscalate)
        XCTAssertEqual(
            repeatedEvaluation.newlyObservedLowLevelIncidentCount,
            0
        )
        XCTAssertEqual(repeatedEvaluation.recentEpisodeCount, 1)
        XCTAssertTrue(repeatedEvaluation.didEndEpisode)
    }

    func testRelaxedDiscardsIncidentsOutsideTenSecondWindow() {
        var gate = AutomaticBufferEscalationGate()

        var cumulativeIncidentCount: UInt64 = 0
        for episodeTime in [1.0, 2.0, 3.0] {
            cumulativeIncidentCount += 1
            _ = gate.evaluate(
                sensitivity: .relaxed,
                routeRequiresEscalation: true,
                cumulativeIncidentCount: cumulativeIncidentCount,
                monotonicTime: episodeTime
            )
            _ = gate.evaluate(
                sensitivity: .relaxed,
                routeRequiresEscalation: true,
                cumulativeIncidentCount: cumulativeIncidentCount,
                monotonicTime: episodeTime + 0.25
            )
        }
        cumulativeIncidentCount += 1
        let evaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: cumulativeIncidentCount,
            monotonicTime: 13.1
        )

        XCTAssertFalse(evaluation.shouldEscalate)
        XCTAssertEqual(evaluation.recentEpisodeCount, 1)
    }

    func testRelaxedCoalescesMultipleLowLevelEventsIntoOneEpisode() {
        var gate = AutomaticBufferEscalationGate()

        let evaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 4,
            monotonicTime: 1
        )

        XCTAssertFalse(evaluation.shouldEscalate)
        XCTAssertEqual(evaluation.newlyObservedLowLevelIncidentCount, 4)
        XCTAssertEqual(evaluation.recentEpisodeCount, 1)
        XCTAssertTrue(evaluation.didStartEpisode)
    }

    func testRelaxedKeepsContinuousCounterGrowthInTheSameEpisode() {
        var gate = AutomaticBufferEscalationGate()

        _ = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 16,
            monotonicTime: 1
        )
        let continuedEvaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 32,
            monotonicTime: 1.5
        )

        XCTAssertFalse(continuedEvaluation.shouldEscalate)
        XCTAssertFalse(continuedEvaluation.didStartEpisode)
        XCTAssertEqual(continuedEvaluation.recentEpisodeCount, 1)
    }

    func testRelaxedEscalatesAnEpisodeThatNeverRecovers() {
        var gate = AutomaticBufferEscalationGate()

        _ = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 16,
            monotonicTime: 1
        )
        let persistentEvaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 64,
            monotonicTime: 3
        )

        XCTAssertTrue(persistentEvaluation.shouldEscalate)
        XCTAssertTrue(persistentEvaluation.isPersistentEpisode)
        XCTAssertEqual(persistentEvaluation.recentEpisodeCount, 1)
    }
}
