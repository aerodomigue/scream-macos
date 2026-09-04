import Foundation

struct AutomaticBufferEscalationEvaluation: Equatable, Sendable {
    let shouldEscalate: Bool
    let newlyObservedIncidentCount: Int
    let recentIncidentCount: Int
}

struct AutomaticBufferEscalationGate: Sendable {
    static let relaxedAllowedIncidentCount = 3
    static let relaxedWindowSeconds: TimeInterval = 10

    private var lastObservedCumulativeIncidentCount: UInt64 = 0
    private var recentIncidentTimes: [TimeInterval] = []

    mutating func evaluate(
        sensitivity: DirectRoutingAutomaticSensitivity,
        routeRequiresEscalation: Bool,
        cumulativeIncidentCount: UInt64,
        monotonicTime: TimeInterval
    ) -> AutomaticBufferEscalationEvaluation {
        guard sensitivity == .relaxed else {
            return AutomaticBufferEscalationEvaluation(
                shouldEscalate: routeRequiresEscalation,
                newlyObservedIncidentCount: routeRequiresEscalation ? 1 : 0,
                recentIncidentCount: routeRequiresEscalation ? 1 : 0
            )
        }

        discardExpiredIncidents(at: monotonicTime)
        let newIncidentCount = newIncidentCount(
            cumulativeIncidentCount: cumulativeIncidentCount
        )
        lastObservedCumulativeIncidentCount = cumulativeIncidentCount

        if routeRequiresEscalation, newIncidentCount > 0 {
            let escalationThreshold = Self.relaxedAllowedIncidentCount + 1
            let remainingIncidentCapacity = max(
                0,
                escalationThreshold - recentIncidentTimes.count
            )
            let recordedIncidentCount = min(
                newIncidentCount,
                UInt64(remainingIncidentCapacity)
            )
            recentIncidentTimes.append(
                contentsOf: repeatElement(
                    monotonicTime,
                    count: Int(recordedIncidentCount)
                )
            )
        }

        return AutomaticBufferEscalationEvaluation(
            shouldEscalate:
                recentIncidentTimes.count > Self.relaxedAllowedIncidentCount,
            newlyObservedIncidentCount: Int(
                min(newIncidentCount, UInt64(Int.max))
            ),
            recentIncidentCount: recentIncidentTimes.count
        )
    }

    mutating func reset() {
        lastObservedCumulativeIncidentCount = 0
        recentIncidentTimes.removeAll(keepingCapacity: true)
    }

    private mutating func discardExpiredIncidents(at monotonicTime: TimeInterval) {
        let cutoff = monotonicTime - Self.relaxedWindowSeconds
        recentIncidentTimes.removeAll { $0 <= cutoff }
    }

    private func newIncidentCount(
        cumulativeIncidentCount: UInt64
    ) -> UInt64 {
        guard cumulativeIncidentCount >= lastObservedCumulativeIncidentCount else {
            return cumulativeIncidentCount
        }
        return cumulativeIncidentCount - lastObservedCumulativeIncidentCount
    }
}
