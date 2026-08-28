import Foundation

enum NominalSampleRateNegotiator {
    static let preferredSampleRate = 48_000.0
    static let secondarySampleRate = 44_100.0
    static let comparisonTolerance = 0.01

    static func negotiate(
        inputRanges: [NominalSampleRateRange],
        outputRanges: [NominalSampleRateRange],
        outputCurrentRate: Double,
        inputUID: AudioDeviceUID,
        outputUID: AudioDeviceUID
    ) throws -> Double {
        let normalizedInputRanges = normalizedRanges(inputRanges)
        let normalizedOutputRanges = normalizedRanges(outputRanges)
        let commonRanges = intersections(normalizedInputRanges, normalizedOutputRanges)

        guard !commonRanges.isEmpty else {
            throw AudioRoutingError.noCommonSampleRate(
                SampleRateCompatibilityContext(
                    inputUID: inputUID,
                    outputUID: outputUID,
                    inputRanges: inputRanges,
                    outputRanges: outputRanges
                )
            )
        }

        if contains(outputCurrentRate, in: commonRanges) {
            return outputCurrentRate
        }
        if contains(preferredSampleRate, in: commonRanges) {
            return preferredSampleRate
        }
        if contains(secondarySampleRate, in: commonRanges) {
            return secondarySampleRate
        }

        let orderedCandidates = commonRanges
            .map { range in
                min(max(preferredSampleRate, range.minimum), range.maximum)
            }
            .sorted { leftRate, rightRate in
                let leftDistance = abs(leftRate - preferredSampleRate)
                let rightDistance = abs(rightRate - preferredSampleRate)
                if abs(leftDistance - rightDistance) <= comparisonTolerance {
                    return leftRate < rightRate
                }
                return leftDistance < rightDistance
            }
        guard let selectedRate = orderedCandidates.first else {
            throw AudioRoutingError.noCommonSampleRate(
                SampleRateCompatibilityContext(
                    inputUID: inputUID,
                    outputUID: outputUID,
                    inputRanges: inputRanges,
                    outputRanges: outputRanges
                )
            )
        }
        return selectedRate
    }

    static func ratesMatch(_ leftRate: Double, _ rightRate: Double) -> Bool {
        abs(leftRate - rightRate) <= comparisonTolerance
    }

    static func normalizedRanges(
        _ ranges: [NominalSampleRateRange]
    ) -> [NominalSampleRateRange] {
        let validRanges = ranges.compactMap { range -> NominalSampleRateRange? in
            guard range.minimum.isFinite,
                  range.maximum.isFinite,
                  range.minimum > 0,
                  range.maximum > 0 else {
                return nil
            }
            return NominalSampleRateRange(
                minimum: min(range.minimum, range.maximum),
                maximum: max(range.minimum, range.maximum)
            )
        }
        .sorted {
            if $0.minimum == $1.minimum {
                return $0.maximum < $1.maximum
            }
            return $0.minimum < $1.minimum
        }

        return validRanges.reduce(into: []) { mergedRanges, range in
            guard let lastRange = mergedRanges.last,
                  range.minimum <= lastRange.maximum else {
                mergedRanges.append(range)
                return
            }
            mergedRanges[mergedRanges.count - 1] = NominalSampleRateRange(
                minimum: lastRange.minimum,
                maximum: max(lastRange.maximum, range.maximum)
            )
        }
    }

    private static func intersections(
        _ inputRanges: [NominalSampleRateRange],
        _ outputRanges: [NominalSampleRateRange]
    ) -> [NominalSampleRateRange] {
        let ranges = inputRanges.flatMap { inputRange in
            outputRanges.compactMap { outputRange -> NominalSampleRateRange? in
                let minimumRate = max(inputRange.minimum, outputRange.minimum)
                let maximumRate = min(inputRange.maximum, outputRange.maximum)
                guard minimumRate <= maximumRate else { return nil }
                return NominalSampleRateRange(minimum: minimumRate, maximum: maximumRate)
            }
        }
        return normalizedRanges(ranges)
    }

    private static func contains(
        _ sampleRate: Double,
        in ranges: [NominalSampleRateRange]
    ) -> Bool {
        ranges.contains { range in
            sampleRate >= range.minimum && sampleRate <= range.maximum
        }
    }
}
