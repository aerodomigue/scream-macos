import Foundation

struct AsyncSRCStabilityCounters: Equatable, Sendable {
    let inputRenderErrorCount: UInt64
    let outputRenderErrorCount: UInt64
    let rateParameterErrorCount: UInt64
    let latencyCeilingOverflowCount: UInt64
    let inputCallbackFrameLimitExceededCount: UInt64
    let outputCallbackFrameLimitExceededCount: UInt64
    let underrunCount: UInt64
    let overflowCount: UInt64
    let resynchronizationCount: UInt64
    let droppedInputFrames: UInt64
    let latencyCeilingUnderrunCount: UInt64
    let inputCallbackDeadlineMissCount: UInt64
    let outputCallbackDeadlineMissCount: UInt64

    static let zero = AsyncSRCStabilityCounters(
        inputRenderErrorCount: 0,
        outputRenderErrorCount: 0,
        rateParameterErrorCount: 0,
        latencyCeilingOverflowCount: 0,
        inputCallbackFrameLimitExceededCount: 0,
        outputCallbackFrameLimitExceededCount: 0,
        underrunCount: 0,
        overflowCount: 0,
        resynchronizationCount: 0,
        droppedInputFrames: 0,
        latencyCeilingUnderrunCount: 0,
        inputCallbackDeadlineMissCount: 0,
        outputCallbackDeadlineMissCount: 0
    )

    init(metrics: AsyncSRCMetrics) {
        inputRenderErrorCount = metrics.inputRenderErrorCount
        outputRenderErrorCount = metrics.outputRenderErrorCount
        rateParameterErrorCount = metrics.rateParameterErrorCount
        latencyCeilingOverflowCount = metrics.latencyCeilingOverflowCount
        inputCallbackFrameLimitExceededCount =
            metrics.inputCallbackFrameLimitExceededCount
        outputCallbackFrameLimitExceededCount =
            metrics.outputCallbackFrameLimitExceededCount
        underrunCount = metrics.underrunCount
        overflowCount = metrics.overflowCount
        resynchronizationCount = metrics.resynchronizationCount
        droppedInputFrames = metrics.droppedInputFrames
        latencyCeilingUnderrunCount = metrics.latencyCeilingUnderrunCount
        inputCallbackDeadlineMissCount = metrics.inputCallbackDeadlineMissCount
        outputCallbackDeadlineMissCount = metrics.outputCallbackDeadlineMissCount
    }

    private init(
        inputRenderErrorCount: UInt64,
        outputRenderErrorCount: UInt64,
        rateParameterErrorCount: UInt64,
        latencyCeilingOverflowCount: UInt64,
        inputCallbackFrameLimitExceededCount: UInt64,
        outputCallbackFrameLimitExceededCount: UInt64,
        underrunCount: UInt64,
        overflowCount: UInt64,
        resynchronizationCount: UInt64,
        droppedInputFrames: UInt64,
        latencyCeilingUnderrunCount: UInt64,
        inputCallbackDeadlineMissCount: UInt64,
        outputCallbackDeadlineMissCount: UInt64
    ) {
        self.inputRenderErrorCount = inputRenderErrorCount
        self.outputRenderErrorCount = outputRenderErrorCount
        self.rateParameterErrorCount = rateParameterErrorCount
        self.latencyCeilingOverflowCount = latencyCeilingOverflowCount
        self.inputCallbackFrameLimitExceededCount =
            inputCallbackFrameLimitExceededCount
        self.outputCallbackFrameLimitExceededCount =
            outputCallbackFrameLimitExceededCount
        self.underrunCount = underrunCount
        self.overflowCount = overflowCount
        self.resynchronizationCount = resynchronizationCount
        self.droppedInputFrames = droppedInputFrames
        self.latencyCeilingUnderrunCount = latencyCeilingUnderrunCount
        self.inputCallbackDeadlineMissCount = inputCallbackDeadlineMissCount
        self.outputCallbackDeadlineMissCount = outputCallbackDeadlineMissCount
    }

    func subtracting(
        _ previous: AsyncSRCStabilityCounters
    ) -> AsyncSRCStabilityCounters {
        AsyncSRCStabilityCounters(
            inputRenderErrorCount: delta(
                inputRenderErrorCount,
                since: previous.inputRenderErrorCount
            ),
            outputRenderErrorCount: delta(
                outputRenderErrorCount,
                since: previous.outputRenderErrorCount
            ),
            rateParameterErrorCount: delta(
                rateParameterErrorCount,
                since: previous.rateParameterErrorCount
            ),
            latencyCeilingOverflowCount: delta(
                latencyCeilingOverflowCount,
                since: previous.latencyCeilingOverflowCount
            ),
            inputCallbackFrameLimitExceededCount: delta(
                inputCallbackFrameLimitExceededCount,
                since: previous.inputCallbackFrameLimitExceededCount
            ),
            outputCallbackFrameLimitExceededCount: delta(
                outputCallbackFrameLimitExceededCount,
                since: previous.outputCallbackFrameLimitExceededCount
            ),
            underrunCount: delta(
                underrunCount,
                since: previous.underrunCount
            ),
            overflowCount: delta(
                overflowCount,
                since: previous.overflowCount
            ),
            resynchronizationCount: delta(
                resynchronizationCount,
                since: previous.resynchronizationCount
            ),
            droppedInputFrames: delta(
                droppedInputFrames,
                since: previous.droppedInputFrames
            ),
            latencyCeilingUnderrunCount: delta(
                latencyCeilingUnderrunCount,
                since: previous.latencyCeilingUnderrunCount
            ),
            inputCallbackDeadlineMissCount: delta(
                inputCallbackDeadlineMissCount,
                since: previous.inputCallbackDeadlineMissCount
            ),
            outputCallbackDeadlineMissCount: delta(
                outputCallbackDeadlineMissCount,
                since: previous.outputCallbackDeadlineMissCount
            )
        )
    }

    var hasMissedCallbackDeadline: Bool {
        inputCallbackDeadlineMissCount > 0
            || outputCallbackDeadlineMissCount > 0
    }

    /// Replaces transport effects while preserving converter and buffer-contract failures.
    func replacingHardwareInterruptionCounters(
        with observed: AsyncSRCStabilityCounters
    ) -> AsyncSRCStabilityCounters {
        AsyncSRCStabilityCounters(
            inputRenderErrorCount: observed.inputRenderErrorCount,
            outputRenderErrorCount: outputRenderErrorCount,
            rateParameterErrorCount: rateParameterErrorCount,
            latencyCeilingOverflowCount: observed.latencyCeilingOverflowCount,
            inputCallbackFrameLimitExceededCount: inputCallbackFrameLimitExceededCount,
            outputCallbackFrameLimitExceededCount: outputCallbackFrameLimitExceededCount,
            underrunCount: observed.underrunCount,
            overflowCount: observed.overflowCount,
            resynchronizationCount: observed.resynchronizationCount,
            droppedInputFrames: observed.droppedInputFrames,
            latencyCeilingUnderrunCount: observed.latencyCeilingUnderrunCount,
            inputCallbackDeadlineMissCount: observed.inputCallbackDeadlineMissCount,
            outputCallbackDeadlineMissCount: observed.outputCallbackDeadlineMissCount
        )
    }

    var totalIncidentCount: UInt64 {
        // droppedInputFrames measures the volume lost, not the number of
        // incidents. Its associated ceiling-overflow or FIFO-overflow event is
        // counted separately below. Wall-clock deadline misses remain telemetry:
        // they cannot distinguish application work from macOS preemption.
        [
            inputRenderErrorCount,
            outputRenderErrorCount,
            rateParameterErrorCount,
            latencyCeilingOverflowCount,
            inputCallbackFrameLimitExceededCount,
            outputCallbackFrameLimitExceededCount,
            underrunCount,
            overflowCount,
            resynchronizationCount,
        ].reduce(0) { partialCount, incidentCount in
            let (sum, overflow) = partialCount.addingReportingOverflow(
                incidentCount
            )
            return overflow ? UInt64.max : sum
        }
    }

    private func delta(_ current: UInt64, since previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}
