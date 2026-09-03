import Foundation

struct AsyncSRCBufferConfiguration: Equatable, Sendable {
    let maximumInputFrames: UInt32
    let maximumOutputFrames: UInt32
    let ringCapacityFrames: UInt32
    let targetFillFrames: UInt32
    let maximumTargetFillFrames: UInt32
    let maximumReadableFrames: UInt32
    let estimatedApplicationLatencySeconds: Double
    let maximumApplicationLatencySeconds: Double
    let isLowLatency: Bool
}

enum AsyncSRCBufferSizing {
    static let defaultDeviceQuantum: UInt32 = 512
    static let minimumMaximumFramesPerSlice: UInt32 = 4_096
    static let converterLookaheadOutputFrames: UInt32 = 33
    static let schedulingSafetySeconds = 0.000_5
    static let preferredApplicationLatencySeconds = 0.005
    static let maximumApplicationLatencySeconds = 0.010
    static let ringCapacityMultiplier: UInt32 = 8
    static let minimumRingCapacity: UInt32 = 2_048

    static func configuration(
        inputBufferFrames: UInt32?,
        outputBufferFrames: UInt32?,
        inputSampleRate: Double,
        outputSampleRate: Double,
        converterLatencySeconds: Double? = nil
    ) -> AsyncSRCBufferConfiguration {
        let inputQuantum = inputBufferFrames ?? defaultDeviceQuantum
        let outputQuantum = outputBufferFrames ?? defaultDeviceQuantum
        let outputQuantumAtInputRate = convertedFrameCount(
            outputQuantum,
            from: outputSampleRate,
            to: inputSampleRate
        )
        let converterLookaheadAtInputRate: UInt32
        let effectiveConverterLatencySeconds: Double
        if let converterLatencySeconds,
           converterLatencySeconds.isFinite,
           converterLatencySeconds >= 0 {
            effectiveConverterLatencySeconds = converterLatencySeconds
            converterLookaheadAtInputRate = UInt32(
                ceil(converterLatencySeconds * inputSampleRate)
            )
        } else {
            effectiveConverterLatencySeconds =
                Double(converterLookaheadOutputFrames) / outputSampleRate
            converterLookaheadAtInputRate = convertedFrameCount(
                converterLookaheadOutputFrames,
                from: outputSampleRate,
                to: inputSampleRate
            )
        }
        let schedulingSafetyFrames = UInt32(
            ceil(schedulingSafetySeconds * inputSampleRate)
        )
        let callbackCoverageFrames: UInt32
        if outputSampleRate > inputSampleRate {
            callbackCoverageFrames = inputQuantum
                + outputQuantumAtInputRate
                + converterLookaheadAtInputRate
        } else {
            callbackCoverageFrames = max(
                inputQuantum,
                outputQuantumAtInputRate + converterLookaheadAtInputRate
            )
        }
        let minimumSafeTargetFillFrames =
            callbackCoverageFrames + schedulingSafetyFrames
        let latencyBudgetFrames = UInt32(
            floor(maximumApplicationLatencySeconds * inputSampleRate)
        )
        let reservedLatencyFrames = converterLookaheadAtInputRate + inputQuantum
        let lowLatencyMaximumTargetFillFrames = latencyBudgetFrames
            > reservedLatencyFrames
            ? latencyBudgetFrames - reservedLatencyFrames
            : 0
        let isLowLatency = minimumSafeTargetFillFrames
            <= lowLatencyMaximumTargetFillFrames
        let targetFillFrames: UInt32
        let maximumTargetFillFrames: UInt32
        if isLowLatency {
            targetFillFrames = minimumSafeTargetFillFrames
            maximumTargetFillFrames = lowLatencyMaximumTargetFillFrames
        } else {
            targetFillFrames = inputQuantum * 2
                + outputQuantumAtInputRate
                + converterLookaheadAtInputRate
            maximumTargetFillFrames = targetFillFrames * 2
        }
        let estimatedApplicationLatencySeconds = applicationLatencySeconds(
            targetFillFrames: targetFillFrames,
            configuredInputQuantumFrames: inputQuantum,
            observedInputQuantumFrames: 0,
            readableFrames: 0,
            inputSampleRate: inputSampleRate,
            converterLatencySeconds: effectiveConverterLatencySeconds
        )
        let maximumInputFrames = max(
            minimumMaximumFramesPerSlice,
            inputQuantum
        )
        let maximumOutputFrames = max(
            minimumMaximumFramesPerSlice,
            outputQuantum
        )
        let targetCapacity = maximumTargetFillFrames > UInt32.max / 2
            ? UInt32.max
            : maximumTargetFillFrames * 2
        let maximumReadableFrames = maximumTargetFillFrames + inputQuantum
        let minimumCapacity = max(
            minimumRingCapacity,
            max(
                maximumInputFrames * 2,
                max(targetFillFrames * ringCapacityMultiplier, targetCapacity)
            )
        )
        return AsyncSRCBufferConfiguration(
            maximumInputFrames: maximumInputFrames,
            maximumOutputFrames: maximumOutputFrames,
            ringCapacityFrames: nextPowerOfTwo(minimumCapacity),
            targetFillFrames: targetFillFrames,
            maximumTargetFillFrames: maximumTargetFillFrames,
            maximumReadableFrames: maximumReadableFrames,
            estimatedApplicationLatencySeconds: estimatedApplicationLatencySeconds,
            maximumApplicationLatencySeconds:
                Double(maximumReadableFrames) / inputSampleRate
                    + effectiveConverterLatencySeconds,
            isLowLatency: isLowLatency
        )
    }

    static func applicationLatencySeconds(
        targetFillFrames: UInt32,
        configuredInputQuantumFrames: UInt32,
        observedInputQuantumFrames: UInt32,
        readableFrames: UInt32,
        inputSampleRate: Double,
        converterLatencySeconds: Double
    ) -> Double {
        guard inputSampleRate.isFinite, inputSampleRate > 0,
              converterLatencySeconds.isFinite,
              converterLatencySeconds >= 0 else {
            return 0
        }
        let effectiveInputQuantum = max(
            configuredInputQuantumFrames,
            observedInputQuantumFrames
        )
        let expectedOccupancy = targetFillFrames + effectiveInputQuantum / 2
        let effectiveOccupancy = max(expectedOccupancy, readableFrames)
        return Double(effectiveOccupancy) / inputSampleRate
            + converterLatencySeconds
    }

    private static func convertedFrameCount(
        _ frameCount: UInt32,
        from sourceSampleRate: Double,
        to destinationSampleRate: Double
    ) -> UInt32 {
        UInt32(ceil(Double(frameCount) * destinationSampleRate / sourceSampleRate))
    }

    private static func nextPowerOfTwo(_ value: UInt32) -> UInt32 {
        guard value > 1 else { return 1 }
        return 1 << (UInt32.bitWidth - (value - 1).leadingZeroBitCount)
    }
}
