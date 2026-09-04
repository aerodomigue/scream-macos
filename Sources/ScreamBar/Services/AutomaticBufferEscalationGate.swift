import Foundation

struct AutomaticBufferEscalationEvaluation: Equatable, Sendable {
    let shouldEscalate: Bool
    let newlyObservedLowLevelIncidentCount: Int
    let recentEpisodeCount: Int
    let didStartEpisode: Bool
    let didEndEpisode: Bool
    let isPersistentEpisode: Bool
}

struct AutomaticBufferEscalationGate: Sendable {
    static let relaxedAllowedIncidentCount = 3
    static let relaxedWindowSeconds: TimeInterval = 10
    static let relaxedPersistentEpisodeSeconds: TimeInterval = 2

    private var lastObservedCumulativeIncidentCount: UInt64 = 0
    private var recentEpisodeTimes: [TimeInterval] = []
    private var activeEpisodeStartTime: TimeInterval?

    mutating func evaluate(
        sensitivity: DirectRoutingAutomaticSensitivity,
        routeRequiresEscalation: Bool,
        cumulativeIncidentCount: UInt64,
        monotonicTime: TimeInterval
    ) -> AutomaticBufferEscalationEvaluation {
        discardExpiredEpisodes(at: monotonicTime)
        let newLowLevelIncidentCount = newIncidentCount(
            cumulativeIncidentCount: cumulativeIncidentCount
        )
        lastObservedCumulativeIncidentCount = cumulativeIncidentCount

        guard sensitivity == .relaxed else {
            return AutomaticBufferEscalationEvaluation(
                shouldEscalate: routeRequiresEscalation,
                newlyObservedLowLevelIncidentCount: Int(
                    min(newLowLevelIncidentCount, UInt64(Int.max))
                ),
                recentEpisodeCount: routeRequiresEscalation ? 1 : 0,
                didStartEpisode: routeRequiresEscalation,
                didEndEpisode: false,
                isPersistentEpisode: false
            )
        }

        let hasNewLowLevelIncident = routeRequiresEscalation
            && newLowLevelIncidentCount > 0
        var didStartEpisode = false
        var didEndEpisode = false
        if hasNewLowLevelIncident {
            if activeEpisodeStartTime == nil {
                activeEpisodeStartTime = monotonicTime
                recentEpisodeTimes.append(monotonicTime)
                didStartEpisode = true
            }
        } else if activeEpisodeStartTime != nil {
            activeEpisodeStartTime = nil
            didEndEpisode = true
        }

        let isPersistentEpisode = activeEpisodeStartTime.map {
            monotonicTime - $0 >= Self.relaxedPersistentEpisodeSeconds
        } ?? false
        return AutomaticBufferEscalationEvaluation(
            shouldEscalate:
                recentEpisodeTimes.count > Self.relaxedAllowedIncidentCount
                || isPersistentEpisode,
            newlyObservedLowLevelIncidentCount: Int(
                min(newLowLevelIncidentCount, UInt64(Int.max))
            ),
            recentEpisodeCount: recentEpisodeTimes.count,
            didStartEpisode: didStartEpisode,
            didEndEpisode: didEndEpisode,
            isPersistentEpisode: isPersistentEpisode
        )
    }

    mutating func reset() {
        lastObservedCumulativeIncidentCount = 0
        recentEpisodeTimes.removeAll(keepingCapacity: true)
        activeEpisodeStartTime = nil
    }

    private mutating func discardExpiredEpisodes(at monotonicTime: TimeInterval) {
        let cutoff = monotonicTime - Self.relaxedWindowSeconds
        recentEpisodeTimes.removeAll { $0 <= cutoff }
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
