@testable import ScreamBar
import AudioToolbox
import AVFAudio
import Foundation
import ScreamBarCoreAudioRT
import XCTest

private let qualityTestInputSampleRate = 48_000.0
private let qualityTestOutputSampleRate = 44_100.0
private let qualityTestAmplitude = 0.5
private let qualityTestFrameChunk: AVAudioFrameCount = 4_096
private let qualityTestWarmupFrames = 8_192
private let qualityTestMeasurementFrames = 44_100
private let qualityTestMaximumLatencySeconds = 0.001
private let qualityTestMinimumSignalToNoiseRatioDecibels = 60.0
private let qualityTestMaximumFrequencyErrorHertz = 0.5
private let qualityTestMinimumGain = 0.90
private let qualityTestMaximumGain = 1.05
private let qualityTestShortQuanta: [AVAudioFrameCount] = [64, 128]
private let qualityTestAdaptiveSettlingSeconds = 5.0
private let qualityTestFallbackSettlingSeconds = 60.0
private let qualityTestFallbackFrameCounts: [UInt32] = [256, 512]
private let qualityTestMaximumTimingJitterSeconds = 0.000_1
private let qualityTestDriftPartsPerMillion = 250.0
private let qualityTestSoakEnvironmentKey =
    "SCREAMBAR_ASYNC_SRC_QUALITY_SOAK_SECONDS"
private let performanceTestSoakEnvironmentKey =
    "SCREAMBAR_ASYNC_SRC_PERFORMANCE_SOAK_SECONDS"
private let fallbackQualityTestSoakEnvironmentKey =
    "SCREAMBAR_ASYNC_SRC_FALLBACK_QUALITY_SOAK_SECONDS"

private struct SampleRatePair {
    let input: Double
    let output: Double
}

private let qualityTestSampleRatePairs = [
    SampleRatePair(input: 32_000, output: 44_100),
    SampleRatePair(input: 44_100, output: 48_000),
    SampleRatePair(input: 48_000, output: 44_100),
    SampleRatePair(input: 48_000, output: 96_000),
    SampleRatePair(input: 96_000, output: 44_100),
    SampleRatePair(input: 192_000, output: 48_000),
]

private struct OfflineVarispeedFailure: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        "\(operation) failed: \(CoreAudioBackendFailure.statusDescription(for: status))"
    }
}

private struct AdaptiveSRCModelFailure: Error, CustomStringConvertible {
    let description: String
}

private final class OfflineToneSource {
    let frequency: Double
    let sampleRate: Double
    private(set) var sourceFrameIndex: Int64 = 0

    init(frequency: Double, sampleRate: Double) {
        self.frequency = frequency
        self.sampleRate = sampleRate
    }

    var consumedFrames: Int64 {
        sourceFrameIndex
    }

    func fill(_ outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for bufferIndex in 0..<buffers.count {
            let buffer = buffers[bufferIndex]
            guard let rawSamples = buffer.mData else { continue }
            let samples = rawSamples.assumingMemoryBound(to: Float32.self)
            for frameIndex in 0..<Int(frameCount) {
                let absoluteFrame = sourceFrameIndex + Int64(frameIndex)
                let phase = 2 * Double.pi * frequency
                    * Double(absoluteFrame) / sampleRate
                samples[frameIndex] = Float32(qualityTestAmplitude * sin(phase))
            }
            buffers[bufferIndex].mDataByteSize =
                frameCount * UInt32(MemoryLayout<Float32>.size)
        }
        sourceFrameIndex += Int64(frameCount)
    }
}

private func offlineToneRenderCallback(
    _ referenceContext: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ outputData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    _ = actionFlags
    _ = timestamp
    _ = busNumber
    guard let outputData else { return kAudio_ParamError }
    let source = Unmanaged<OfflineToneSource>
        .fromOpaque(referenceContext)
        .takeUnretainedValue()
    source.fill(outputData, frameCount: frameCount)
    return noErr
}

private final class OfflineVarispeedHarness {
    private var audioUnit: AudioUnit?
    private let source: OfflineToneSource
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double
    private let outputSampleRate: Double
    private var outputSampleTime: Float64 = 0
    private(set) var converterLatencySeconds: Double = 0

    var consumedSourceFrames: Int64 {
        source.consumedFrames
    }

    init(
        frequency: Double,
        inputSampleRate: Double = qualityTestInputSampleRate,
        outputSampleRate: Double = qualityTestOutputSampleRate,
        inputClockScalar: Double = 1
    ) throws {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        source = OfflineToneSource(
            frequency: frequency,
            sampleRate: inputSampleRate * inputClockScalar
        )
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputSampleRate,
            channels: 2
        ) else {
            throw OfflineVarispeedFailure(
                operation: "Create output format",
                status: kAudio_ParamError
            )
        }
        self.outputFormat = outputFormat

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_Varispeed,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw OfflineVarispeedFailure(
                operation: "Find Varispeed Audio Unit",
                status: kAudio_ParamError
            )
        }
        var createdAudioUnit: AudioUnit?
        try Self.requireNoError(
            AudioComponentInstanceNew(component, &createdAudioUnit),
            operation: "Create Varispeed Audio Unit"
        )
        guard let createdAudioUnit else {
            throw OfflineVarispeedFailure(
                operation: "Create Varispeed Audio Unit",
                status: kAudio_ParamError
            )
        }
        audioUnit = createdAudioUnit

        do {
            try configure(createdAudioUnit)
        } catch {
            AudioComponentInstanceDispose(createdAudioUnit)
            audioUnit = nil
            throw error
        }
    }

    deinit {
        guard let audioUnit else { return }
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }

    func render(
        frameCount: Int,
        quantum: AVAudioFrameCount = qualityTestFrameChunk
    ) throws -> [Float32] {
        guard frameCount >= 0, quantum > 0, let audioUnit else {
            throw OfflineVarispeedFailure(
                operation: "Render Varispeed Audio Unit",
                status: kAudio_ParamError
            )
        }
        var renderedSamples: [Float32] = []
        renderedSamples.reserveCapacity(frameCount)
        var remainingFrames = frameCount
        while remainingFrames > 0 {
            let currentFrameCount = AVAudioFrameCount(
                min(remainingFrames, Int(quantum))
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: currentFrameCount
            ), let channelSamples = outputBuffer.floatChannelData?[0] else {
                throw OfflineVarispeedFailure(
                    operation: "Allocate output buffer",
                    status: kAudio_MemFullError
                )
            }
            outputBuffer.frameLength = currentFrameCount
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = outputSampleTime
            timestamp.mFlags = .sampleTimeValid
            var actionFlags = AudioUnitRenderActionFlags()
            try Self.requireNoError(
                AudioUnitRender(
                    audioUnit,
                    &actionFlags,
                    &timestamp,
                    0,
                    currentFrameCount,
                    outputBuffer.mutableAudioBufferList
                ),
                operation: "Render Varispeed Audio Unit"
            )
            renderedSamples.append(
                contentsOf: UnsafeBufferPointer(
                    start: channelSamples,
                    count: Int(currentFrameCount)
                )
            )
            outputSampleTime += Float64(currentFrameCount)
            remainingFrames -= Int(currentFrameCount)
        }
        return renderedSamples
    }

    func setPlaybackRate(_ playbackRate: Double) throws {
        guard let audioUnit else {
            throw OfflineVarispeedFailure(
                operation: "Set Varispeed playback rate",
                status: kAudio_ParamError
            )
        }
        try Self.requireNoError(
            AudioUnitSetParameter(
                audioUnit,
                kVarispeedParam_PlaybackRate,
                kAudioUnitScope_Global,
                0,
                AudioUnitParameterValue(playbackRate),
                0
            ),
            operation: "Set Varispeed playback rate"
        )
    }

    func close() throws {
        guard let audioUnit else { return }
        var emptyCallback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        try Self.requireNoError(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &emptyCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "Remove offline source callback"
        )
        let uninitializeStatus = AudioUnitUninitialize(audioUnit)
        guard uninitializeStatus == noErr
                || uninitializeStatus == kAudioUnitErr_Uninitialized else {
            throw OfflineVarispeedFailure(
                operation: "Uninitialize Varispeed Audio Unit",
                status: uninitializeStatus
            )
        }
        try Self.requireNoError(
            AudioComponentInstanceDispose(audioUnit),
            operation: "Dispose Varispeed Audio Unit"
        )
        self.audioUnit = nil
    }

    private func configure(_ audioUnit: AudioUnit) throws {
        var maximumFrames = UInt32(qualityTestFrameChunk)
        try Self.requireNoError(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maximumFrames,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "Set maximum Varispeed frames"
        )

        var inputFormat = AsyncSRCPlaythrough.makeClientFormat(
            sampleRate: inputSampleRate,
            channelCount: 2
        )
        var outputStreamFormat = AsyncSRCPlaythrough.makeClientFormat(
            sampleRate: outputSampleRate,
            channelCount: 2
        )
        try Self.setFormat(
            &inputFormat,
            on: audioUnit,
            scope: kAudioUnitScope_Input
        )
        try Self.setFormat(
            &outputStreamFormat,
            on: audioUnit,
            scope: kAudioUnitScope_Output
        )

        var renderQuality = UInt32(kRenderQuality_High)
        try Self.requireNoError(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_RenderQuality,
                kAudioUnitScope_Global,
                0,
                &renderQuality,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "Set Varispeed render quality"
        )

        var callback = AURenderCallbackStruct(
            inputProc: offlineToneRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(source).toOpaque()
        )
        try Self.requireNoError(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "Set offline source callback"
        )
        try Self.requireNoError(
            AudioUnitInitialize(audioUnit),
            operation: "Initialize Varispeed Audio Unit"
        )
        try Self.requireNoError(
            AudioUnitSetParameter(
                audioUnit,
                kVarispeedParam_PlaybackRate,
                kAudioUnitScope_Global,
                0,
                1,
                0
            ),
            operation: "Set Varispeed playback rate"
        )

        var latency = Float64.zero
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        try Self.requireNoError(
            AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_Latency,
                kAudioUnitScope_Global,
                0,
                &latency,
                &latencySize
            ),
            operation: "Read Varispeed latency"
        )
        converterLatencySeconds = latency
    }

    private static func setFormat(
        _ format: inout AudioStreamBasicDescription,
        on audioUnit: AudioUnit,
        scope: AudioUnitScope
    ) throws {
        try requireNoError(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                scope,
                0,
                &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            operation: "Set Varispeed stream format"
        )
    }

    private static func requireNoError(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw OfflineVarispeedFailure(operation: operation, status: status)
        }
    }
}

private struct ToneQualityMetrics {
    let frequencyHertz: Double
    let gain: Double
    let signalToNoiseRatioDecibels: Double
}

final class AsyncSRCSignalQualityTests: XCTestCase {
    func testFortyEightToFortyFourPointOnePreservesPitchGainAndFidelity() throws {
        for frequency in [250.0, 997.0, 5_000.0, 10_000.0, 18_000.0] {
            let metrics = try measureTone(frequency: frequency)
            assertQuality(metrics, expectedFrequency: frequency)
        }
    }

    func testCommonConversionMatrixPreservesPitchGainAndFidelity() throws {
        for pair in qualityTestSampleRatePairs {
            let maximumTestFrequency = min(pair.input, pair.output) * 0.2
            for frequency in [997.0, maximumTestFrequency] {
                let metrics = try measureTone(
                    frequency: frequency,
                    inputSampleRate: pair.input,
                    outputSampleRate: pair.output
                )
                assertQuality(metrics, expectedFrequency: frequency)
            }
        }
    }

    func testShortQuantumConversionMatrixPreservesPitchGainAndFidelity() throws {
        for pair in qualityTestSampleRatePairs {
            for quantum in qualityTestShortQuanta {
                let metrics = try measureTone(
                    frequency: 997,
                    inputSampleRate: pair.input,
                    outputSampleRate: pair.output,
                    quantum: quantum
                )
                assertQuality(
                    metrics,
                    expectedFrequency: 997,
                    context: "\(Int(pair.input)) → \(Int(pair.output)) Hz, \(quantum) frames"
                )
            }
        }
    }

    func testAdaptiveClockControlPreservesFidelityWithDriftAndJitter() throws {
        try assertAdaptiveRoutingQualityMatrix()
    }

    func testAdaptiveRoutingQualityDuringRequestedSoak() throws {
        let duration = requestedDuration(
            environmentKey: qualityTestSoakEnvironmentKey
        )
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            try assertAdaptiveRoutingQualityMatrix()
        } while Date() < deadline
    }

    func testFallbackRoutingPreservesFidelityWithDriftAndJitter() throws {
        try assertFallbackRoutingQualityMatrix()
    }

    func testFallbackRoutingQualityDuringRequestedSoak() throws {
        let duration = requestedDuration(
            environmentKey: fallbackQualityTestSoakEnvironmentKey
        )
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            try assertFallbackRoutingQualityMatrix()
        } while Date() < deadline
    }

    func testVarispeedReportsSubMillisecondConverterLatency() throws {
        for pair in qualityTestSampleRatePairs {
            let harness = try OfflineVarispeedHarness(
                frequency: 997,
                inputSampleRate: pair.input,
                outputSampleRate: pair.output
            )
            XCTAssertLessThanOrEqual(
                harness.converterLatencySeconds,
                qualityTestMaximumLatencySeconds,
                "\(Int(pair.input)) → \(Int(pair.output)) converter latency was \(harness.converterLatencySeconds * 1_000) ms"
            )
            try harness.close()
        }
    }

    func testIndependentCallbackPhasingDoesNotCreateAudibleRateModulation() throws {
        let harness = try OfflineVarispeedHarness(frequency: 997)
        defer { XCTAssertNoThrow(try harness.close()) }
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }
        let inputQuantum = 512
        let outputQuantum = 512
        let targetFillFrames = 1_618
        let inputPeriod = Double(inputQuantum) / qualityTestInputSampleRate
        let outputPeriod = Double(outputQuantum) / qualityTestOutputSampleRate
        let callbackCount = Int(ceil(
            10 * qualityTestOutputSampleRate / Double(outputQuantum)
        ))
        var nextInputTime = inputPeriod
        var outputTime = 0.0
        var modeledReadableFrames = Double(targetFillFrames + inputQuantum / 2)
        var convertedSamples: [Float32] = []
        convertedSamples.reserveCapacity(callbackCount * outputQuantum)

        for _ in 0..<callbackCount {
            while nextInputTime <= outputTime {
                modeledReadableFrames += Double(inputQuantum)
                nextInputTime += inputPeriod
            }
            let playbackRate = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                UInt32(max(0, modeledReadableFrames.rounded())),
                UInt32(targetFillFrames),
                UInt32(outputQuantum),
                qualityTestInputSampleRate,
                qualityTestOutputSampleRate,
                false
            )
            try harness.setPlaybackRate(playbackRate)
            let consumedBefore = harness.consumedSourceFrames
            convertedSamples.append(
                contentsOf: try harness.render(frameCount: outputQuantum)
            )
            let consumedFrames = harness.consumedSourceFrames - consumedBefore
            modeledReadableFrames -= Double(consumedFrames)
            XCTAssertGreaterThan(modeledReadableFrames, 0)
            outputTime += outputPeriod
        }

        let measurementSamples = Array(
            convertedSamples.suffix(qualityTestMeasurementFrames)
        )
        let metrics = analyzeTone(
            measurementSamples,
            expectedFrequency: 997,
            fitsMeasuredFrequencyForNoise: true
        )
        assertQuality(metrics, expectedFrequency: 997)
    }

    func testFidelityAndDistortionRemainStableDuringRequestedSoak() throws {
        let duration = requestedDuration(
            environmentKey: qualityTestSoakEnvironmentKey
        )
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            let metrics = try measureTone(frequency: 997)
            assertQuality(metrics, expectedFrequency: 997)
        } while Date() < deadline
    }

    func testConversionMatrixQualityDuringRequestedSoak() throws {
        let duration = requestedDuration(
            environmentKey: qualityTestSoakEnvironmentKey
        )
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            for pair in qualityTestSampleRatePairs {
                let metrics = try measureTone(
                    frequency: 997,
                    inputSampleRate: pair.input,
                    outputSampleRate: pair.output
                )
                assertQuality(metrics, expectedFrequency: 997)
            }
        } while Date() < deadline
    }

    func testConversionKeepsRealtimePerformanceHeadroomDuringRequestedSoak() throws {
        let harness = try OfflineVarispeedHarness(frequency: 997)
        defer { XCTAssertNoThrow(try harness.close()) }
        _ = try harness.render(frameCount: qualityTestWarmupFrames)
        let duration = requestedDuration(
            environmentKey: performanceTestSoakEnvironmentKey
        )
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            let startedAt = ContinuousClock.now
            _ = try harness.render(frameCount: qualityTestMeasurementFrames)
            let processingSeconds = secondsSince(startedAt)
            XCTAssertLessThan(
                processingSeconds,
                1,
                "One second of converted audio took \(processingSeconds) seconds"
            )
        } while Date() < deadline
    }

    func testConversionMatrixKeepsRealtimePerformanceHeadroomDuringRequestedSoak() throws {
        let duration = requestedDuration(
            environmentKey: performanceTestSoakEnvironmentKey
        )
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            for pair in qualityTestSampleRatePairs {
                let harness = try OfflineVarispeedHarness(
                    frequency: 997,
                    inputSampleRate: pair.input,
                    outputSampleRate: pair.output
                )
                let measurementFrameCount = Int(pair.output)
                _ = try harness.render(frameCount: qualityTestWarmupFrames)
                let startedAt = ContinuousClock.now
                _ = try harness.render(frameCount: measurementFrameCount)
                let processingSeconds = secondsSince(startedAt)
                XCTAssertLessThan(
                    processingSeconds,
                    1,
                    "One second of \(Int(pair.input)) → \(Int(pair.output)) audio took \(processingSeconds) seconds"
                )
                try harness.close()
            }
        } while Date() < deadline
    }

    func testShortQuantumConversionMatrixKeepsRealtimePerformanceHeadroom() throws {
        for pair in qualityTestSampleRatePairs {
            for quantum in qualityTestShortQuanta {
                let harness = try OfflineVarispeedHarness(
                    frequency: 997,
                    inputSampleRate: pair.input,
                    outputSampleRate: pair.output
                )
                _ = try harness.render(
                    frameCount: qualityTestWarmupFrames,
                    quantum: quantum
                )
                let measurementFrameCount = Int(pair.output)
                let realtimeBudgetSeconds = Double(measurementFrameCount)
                    / pair.output
                let startedAt = ContinuousClock.now
                _ = try harness.render(
                    frameCount: measurementFrameCount,
                    quantum: quantum
                )
                let processingSeconds = secondsSince(startedAt)
                XCTAssertLessThan(
                    processingSeconds,
                    realtimeBudgetSeconds,
                    "\(Int(pair.input)) → \(Int(pair.output)) Hz at \(quantum) frames used \(processingSeconds) s of its \(realtimeBudgetSeconds) s real-time budget"
                )
                try harness.close()
            }
        }
    }

    private func measureTone(
        frequency: Double,
        inputSampleRate: Double = qualityTestInputSampleRate,
        outputSampleRate: Double = qualityTestOutputSampleRate,
        quantum: AVAudioFrameCount = qualityTestFrameChunk
    ) throws -> ToneQualityMetrics {
        let harness = try OfflineVarispeedHarness(
            frequency: frequency,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        defer { XCTAssertNoThrow(try harness.close()) }
        _ = try harness.render(
            frameCount: qualityTestWarmupFrames,
            quantum: quantum
        )
        let samples = try harness.render(
            frameCount: Int(outputSampleRate),
            quantum: quantum
        )
        return analyzeTone(
            samples,
            expectedFrequency: frequency,
            outputSampleRate: outputSampleRate
        )
    }

    private func measureAdaptivelyControlledTone(
        frequency: Double,
        inputSampleRate: Double,
        outputSampleRate: Double,
        frameCount: UInt32,
        inputDriftPartsPerMillion: Double,
        settlingSeconds: TimeInterval = qualityTestAdaptiveSettlingSeconds
    ) throws -> ToneQualityMetrics {
        let inputClockScalar = 1
            + inputDriftPartsPerMillion / 1_000_000
        let harness = try OfflineVarispeedHarness(
            frequency: frequency,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate,
            inputClockScalar: inputClockScalar
        )
        defer { XCTAssertNoThrow(try harness.close()) }
        let controller = try XCTUnwrap(ScreamBarAsyncSRCClockControllerCreate())
        defer { ScreamBarAsyncSRCClockControllerDestroy(controller) }
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: frameCount,
            outputBufferFrames: frameCount,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate,
            converterLatencySeconds: harness.converterLatencySeconds
        )
        let inputPeriod = Double(frameCount)
            / (inputSampleRate * inputClockScalar)
        let outputPeriod = Double(frameCount) / outputSampleRate
        let primingThreshold = configuration.targetFillFrames
            + min(
                frameCount / 2,
                configuration.maximumTargetFillFrames
                    - configuration.targetFillFrames
            )
        var readableFrames = Double(
            ((primingThreshold + frameCount - 1) / frameCount) * frameCount
        )
        let settlingCallbackCount = Int(ceil(
            settlingSeconds * outputSampleRate / Double(frameCount)
        ))
        let measurementFrameCount = Int(outputSampleRate)
        let measurementCallbackCount = Int(ceil(
            outputSampleRate / Double(frameCount)
        ))
        let callbackCount = settlingCallbackCount + measurementCallbackCount
        var inputCallbackIndex = 1
        var outputCallbackIndex = 0
        var nextInputTime = inputPeriod
        var outputTime = 0.0
        var convertedSamples: [Float32] = []
        convertedSamples.reserveCapacity(
            measurementCallbackCount * Int(frameCount)
        )

        for _ in 0..<callbackCount {
            while nextInputTime <= outputTime {
                readableFrames += Double(frameCount)
                guard readableFrames
                        <= Double(configuration.ringCapacityFrames) else {
                    throw AdaptiveSRCModelFailure(
                        description: "Modeled overflow for \(Int(inputSampleRate)) → \(Int(outputSampleRate)) Hz at \(inputDriftPartsPerMillion) ppm"
                    )
                }
                inputCallbackIndex += 1
                nextInputTime = Double(inputCallbackIndex) * inputPeriod
                    + deterministicTimingJitter(
                        index: inputCallbackIndex,
                        phase: 0.37
                    )
            }
            let playbackRate = ScreamBarAsyncSRCClockControllerUpdate(
                controller,
                UInt32(max(0, readableFrames.rounded())),
                configuration.targetFillFrames,
                frameCount,
                inputSampleRate,
                outputSampleRate,
                AsyncSRCClockControlPolicy.usesAdaptiveControl(
                    inputBufferFrames: frameCount,
                    outputBufferFrames: frameCount
                )
            )
            try harness.setPlaybackRate(playbackRate)
            let consumedBefore = harness.consumedSourceFrames
            let renderedSamples = try harness.render(
                frameCount: Int(frameCount),
                quantum: frameCount
            )
            if outputCallbackIndex >= settlingCallbackCount {
                convertedSamples.append(contentsOf: renderedSamples)
            }
            let consumedFrames = Double(
                harness.consumedSourceFrames - consumedBefore
            )
            guard readableFrames >= consumedFrames else {
                throw AdaptiveSRCModelFailure(
                    description: "Modeled underrun for \(Int(inputSampleRate)) → \(Int(outputSampleRate)) Hz at \(inputDriftPartsPerMillion) ppm"
                )
            }
            readableFrames -= consumedFrames
            outputCallbackIndex += 1
            outputTime = Double(outputCallbackIndex) * outputPeriod
                + deterministicTimingJitter(
                    index: outputCallbackIndex,
                    phase: 1.91
                )
        }

        return analyzeTone(
            Array(convertedSamples.suffix(measurementFrameCount)),
            expectedFrequency: frequency,
            outputSampleRate: outputSampleRate,
            fitsMeasuredFrequencyForNoise: true
        )
    }

    private func assertAdaptiveRoutingQualityMatrix() throws {
        let pairs = [
            SampleRatePair(input: 44_100, output: 48_000),
            SampleRatePair(input: 48_000, output: 44_100),
        ]
        for pair in pairs {
            for frameCount: UInt32 in [64, 128] {
                for driftPartsPerMillion in [
                    -qualityTestDriftPartsPerMillion,
                    qualityTestDriftPartsPerMillion,
                ] {
                    let metrics = try measureAdaptivelyControlledTone(
                        frequency: 997,
                        inputSampleRate: pair.input,
                        outputSampleRate: pair.output,
                        frameCount: frameCount,
                        inputDriftPartsPerMillion: driftPartsPerMillion
                    )
                    assertQuality(
                        metrics,
                        expectedFrequency: 997,
                        context: "\(Int(pair.input)) → \(Int(pair.output)) Hz, \(frameCount) frames, \(driftPartsPerMillion) ppm"
                    )
                }
            }
        }
    }

    private func assertFallbackRoutingQualityMatrix() throws {
        let pairs = [
            SampleRatePair(input: 44_100, output: 48_000),
            SampleRatePair(input: 48_000, output: 44_100),
        ]
        for pair in pairs {
            for frameCount in qualityTestFallbackFrameCounts {
                XCTAssertFalse(
                    AsyncSRCClockControlPolicy.usesAdaptiveControl(
                        inputBufferFrames: frameCount,
                        outputBufferFrames: frameCount
                    ),
                    "\(frameCount) frames must exercise fallback clock control"
                )
                for driftPartsPerMillion in [
                    -qualityTestDriftPartsPerMillion,
                    qualityTestDriftPartsPerMillion,
                ] {
                    let metrics = try measureAdaptivelyControlledTone(
                        frequency: 997,
                        inputSampleRate: pair.input,
                        outputSampleRate: pair.output,
                        frameCount: frameCount,
                        inputDriftPartsPerMillion: driftPartsPerMillion,
                        settlingSeconds: qualityTestFallbackSettlingSeconds
                    )
                    assertQuality(
                        metrics,
                        expectedFrequency: 997,
                        context: "fallback \(Int(pair.input)) → \(Int(pair.output)) Hz, \(frameCount) frames, \(driftPartsPerMillion) ppm"
                    )
                }
            }
        }
    }

    private func analyzeTone(
        _ samples: [Float32],
        expectedFrequency: Double,
        outputSampleRate: Double = qualityTestOutputSampleRate,
        fitsMeasuredFrequencyForNoise: Bool = false
    ) -> ToneQualityMetrics {
        let sampleCount = Double(samples.count)
        let mean = samples.reduce(0) { $0 + Double($1) } / sampleCount
        var positiveCrossings: [Double] = []
        for index in 1..<samples.count {
            let previousSample = Double(samples[index - 1]) - mean
            let currentSample = Double(samples[index]) - mean
            guard previousSample <= 0, currentSample > 0 else { continue }
            let fraction = -previousSample / (currentSample - previousSample)
            positiveCrossings.append(Double(index - 1) + fraction)
        }
        let measuredFrequency: Double
        if let firstCrossing = positiveCrossings.first,
           let lastCrossing = positiveCrossings.last,
           positiveCrossings.count > 1 {
            measuredFrequency = outputSampleRate
                * Double(positiveCrossings.count - 1)
                / (lastCrossing - firstCrossing)
        } else {
            measuredFrequency = .nan
        }
        let fittedFrequency = fitsMeasuredFrequencyForNoise
            ? bestFittingFrequency(
                samples,
                mean: mean,
                expectedFrequency: expectedFrequency,
                outputSampleRate: outputSampleRate
            )
            : expectedFrequency
        let angularFrequency = 2 * Double.pi * fittedFrequency
            / outputSampleRate
        var sineProjection = 0.0
        var cosineProjection = 0.0
        for (index, sample) in samples.enumerated() {
            let centeredSample = Double(sample) - mean
            let phase = angularFrequency * Double(index)
            sineProjection += centeredSample * sin(phase)
            cosineProjection += centeredSample * cos(phase)
        }
        let sineAmplitude = 2 * sineProjection / sampleCount
        let cosineAmplitude = 2 * cosineProjection / sampleCount
        let measuredAmplitude = hypot(sineAmplitude, cosineAmplitude)
        var signalEnergy = 0.0
        var residualEnergy = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = angularFrequency * Double(index)
            let fittedSignal = sineAmplitude * sin(phase)
                + cosineAmplitude * cos(phase)
            let residual = Double(sample) - mean - fittedSignal
            signalEnergy += fittedSignal * fittedSignal
            residualEnergy += residual * residual
        }
        let signalToNoiseRatio = 10 * log10(signalEnergy / residualEnergy)

        return ToneQualityMetrics(
            frequencyHertz: measuredFrequency,
            gain: measuredAmplitude / qualityTestAmplitude,
            signalToNoiseRatioDecibels: signalToNoiseRatio
        )
    }

    private func bestFittingFrequency(
        _ samples: [Float32],
        mean: Double,
        expectedFrequency: Double,
        outputSampleRate: Double
    ) -> Double {
        let searchHalfWidth = qualityTestMaximumFrequencyErrorHertz
        let goldenRatio = (sqrt(5.0) - 1) / 2
        var lowerBound = expectedFrequency - searchHalfWidth
        var upperBound = expectedFrequency + searchHalfWidth
        var lowerCandidate = upperBound
            - goldenRatio * (upperBound - lowerBound)
        var upperCandidate = lowerBound
            + goldenRatio * (upperBound - lowerBound)
        var lowerEnergy = projectedToneEnergy(
            samples,
            mean: mean,
            frequency: lowerCandidate,
            outputSampleRate: outputSampleRate
        )
        var upperEnergy = projectedToneEnergy(
            samples,
            mean: mean,
            frequency: upperCandidate,
            outputSampleRate: outputSampleRate
        )

        for _ in 0..<32 {
            if lowerEnergy < upperEnergy {
                lowerBound = lowerCandidate
                lowerCandidate = upperCandidate
                lowerEnergy = upperEnergy
                upperCandidate = lowerBound
                    + goldenRatio * (upperBound - lowerBound)
                upperEnergy = projectedToneEnergy(
                    samples,
                    mean: mean,
                    frequency: upperCandidate,
                    outputSampleRate: outputSampleRate
                )
            } else {
                upperBound = upperCandidate
                upperCandidate = lowerCandidate
                upperEnergy = lowerEnergy
                lowerCandidate = upperBound
                    - goldenRatio * (upperBound - lowerBound)
                lowerEnergy = projectedToneEnergy(
                    samples,
                    mean: mean,
                    frequency: lowerCandidate,
                    outputSampleRate: outputSampleRate
                )
            }
        }
        return (lowerBound + upperBound) / 2
    }

    private func projectedToneEnergy(
        _ samples: [Float32],
        mean: Double,
        frequency: Double,
        outputSampleRate: Double
    ) -> Double {
        let angularFrequency = 2 * Double.pi * frequency / outputSampleRate
        var sineProjection = 0.0
        var cosineProjection = 0.0
        for (index, sample) in samples.enumerated() {
            let centeredSample = Double(sample) - mean
            let phase = angularFrequency * Double(index)
            sineProjection += centeredSample * sin(phase)
            cosineProjection += centeredSample * cos(phase)
        }
        return sineProjection * sineProjection
            + cosineProjection * cosineProjection
    }

    private func assertQuality(
        _ metrics: ToneQualityMetrics,
        expectedFrequency: Double,
        context: String = ""
    ) {
        let diagnosticContext = context.isEmpty ? "" : " [\(context)]"
        XCTAssertTrue(
            metrics.frequencyHertz.isFinite
                && metrics.gain.isFinite
                && metrics.signalToNoiseRatioDecibels.isFinite,
            "Non-finite/corrupt audio metrics: \(metrics)\(diagnosticContext)"
        )
        XCTAssertEqual(
            metrics.frequencyHertz,
            expectedFrequency,
            accuracy: qualityTestMaximumFrequencyErrorHertz,
            "Pitch changed: \(metrics)\(diagnosticContext)"
        )
        XCTAssertGreaterThanOrEqual(
            metrics.gain,
            qualityTestMinimumGain,
            "Excessive attenuation: \(metrics)\(diagnosticContext)"
        )
        XCTAssertLessThanOrEqual(
            metrics.gain,
            qualityTestMaximumGain,
            "Excessive gain: \(metrics)\(diagnosticContext)"
        )
        XCTAssertGreaterThanOrEqual(
            metrics.signalToNoiseRatioDecibels,
            qualityTestMinimumSignalToNoiseRatioDecibels,
            "Excessive distortion or noise: \(metrics)\(diagnosticContext)"
        )
    }

    private func deterministicTimingJitter(
        index: Int,
        phase: Double
    ) -> Double {
        sin(Double(index) * 0.731 + phase)
            * qualityTestMaximumTimingJitterSeconds
    }

    private func requestedDuration(environmentKey: String) -> TimeInterval {
        guard let rawDuration = ProcessInfo.processInfo.environment[environmentKey],
              let duration = TimeInterval(rawDuration), duration > 0 else {
            return 0
        }
        return duration
    }

    private func secondsSince(_ instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
