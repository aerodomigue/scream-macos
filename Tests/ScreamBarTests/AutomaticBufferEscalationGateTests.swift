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

        for incidentCount in 1...3 {
            let evaluation = gate.evaluate(
                sensitivity: .relaxed,
                routeRequiresEscalation: true,
                cumulativeIncidentCount: UInt64(incidentCount),
                monotonicTime: TimeInterval(incidentCount)
            )
            XCTAssertFalse(evaluation.shouldEscalate)
            XCTAssertEqual(evaluation.recentIncidentCount, incidentCount)
        }

        let fourthEvaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 4,
            monotonicTime: 4
        )

        XCTAssertTrue(fourthEvaluation.shouldEscalate)
        XCTAssertEqual(fourthEvaluation.recentIncidentCount, 4)
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
        XCTAssertEqual(repeatedEvaluation.newlyObservedIncidentCount, 0)
        XCTAssertEqual(repeatedEvaluation.recentIncidentCount, 1)
    }

    func testRelaxedDiscardsIncidentsOutsideTenSecondWindow() {
        var gate = AutomaticBufferEscalationGate()

        _ = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 3,
            monotonicTime: 1
        )
        let evaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 4,
            monotonicTime: 11.1
        )

        XCTAssertFalse(evaluation.shouldEscalate)
        XCTAssertEqual(evaluation.recentIncidentCount, 1)
    }

    func testRelaxedCountsMultipleNewIncidentsReportedInOnePoll() {
        var gate = AutomaticBufferEscalationGate()

        let evaluation = gate.evaluate(
            sensitivity: .relaxed,
            routeRequiresEscalation: true,
            cumulativeIncidentCount: 4,
            monotonicTime: 1
        )

        XCTAssertTrue(evaluation.shouldEscalate)
        XCTAssertEqual(evaluation.newlyObservedIncidentCount, 4)
    }
}
