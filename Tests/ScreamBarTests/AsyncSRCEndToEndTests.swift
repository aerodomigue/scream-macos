@testable import ScreamBar
import AudioToolbox
import AVFAudio
import Foundation
import ScreamBarCoreAudioRT
import XCTest

private let endToEndChannelCount: UInt32 = 2
private let endToEndDurationSeconds = 8.0
private let endToEndMinimumMeasuredSeconds = 2.0
private let endToEndQualityMeasurementSeconds = 1.0
private let endToEndMinimumSignalToNoiseRatioDecibels = 50.0
private let endToEndMinimumGain = 0.90
private let endToEndMaximumGain = 1.05

private struct EndToEndScenario {
    let inputSampleRate: Double
    let outputSampleRate: Double
    let quantum: UInt32

    var description: String {
        "\(Int(inputSampleRate)) → \(Int(outputSampleRate)) Hz, \(quantum) frames"
    }
}

private struct EndToEndTone {
    let frequency: Double
    let amplitude: Double
}

private let endToEndDefaultScenario = EndToEndScenario(
    inputSampleRate: 48_000,
    outputSampleRate: 44_100,
    quantum: 128
)
private let endToEndConversionScenarios = [
    EndToEndScenario(
        inputSampleRate: 44_100,
        outputSampleRate: 48_000,
        quantum: 64
    ),
    EndToEndScenario(
        inputSampleRate: 96_000,
        outputSampleRate: 44_100,
        quantum: 128
    ),
]
private let endToEndChannelTones = [
    [
        EndToEndTone(frequency: 997, amplitude: 0.26),
        EndToEndTone(frequency: 4_031, amplitude: 0.13),
    ],
    [
        EndToEndTone(frequency: 503, amplitude: 0.22),
        EndToEndTone(frequency: 7_013, amplitude: 0.12),
    ],
]

private struct EndToEndFailure: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        "\(operation) failed: \(CoreAudioBackendFailure.statusDescription(for: status))"
    }
}

private struct EndToEndCleanupFailure: Error, CustomStringConvertible {
    let failures: [EndToEndFailure]

    var description: String {
        failures.map(\.description).joined(separator: "; ")
    }
}

private final class EndToEndInputSignalSource {
    private let sampleRate: Double
    private let includesImpulse: Bool
    private var frameIndex: Int64 = 0

    init(sampleRate: Double, includesImpulse: Bool) {
        self.sampleRate = sampleRate
        self.includesImpulse = includesImpulse
    }

    func render(
        into outputData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard buffers.count >= Int(endToEndChannelCount) else {
            return kAudio_ParamError
        }
        for channel in 0..<Int(endToEndChannelCount) {
            guard let rawSamples = buffers[channel].mData else {
                return kAudio_ParamError
            }
            let samples = rawSamples.assumingMemoryBound(to: Float32.self)
            for localFrame in 0..<Int(frameCount) {
                let absoluteFrame = frameIndex + Int64(localFrame)
                let time = Double(absoluteFrame) / sampleRate
                let impulsePhase = Int(absoluteFrame % 4_096)
                let impulse: Double
                if includesImpulse, impulsePhase == 211, channel == 0 {
                    impulse = 0.22
                } else {
                    impulse = 0
                }
                let sample = endToEndChannelTones[channel].reduce(impulse) {
                    partialSample, tone in
                    partialSample + tone.amplitude
                        * sin(2 * .pi * tone.frequency * time)
                }
                samples[localFrame] = Float32(sample)
            }
            buffers[channel].mDataByteSize = frameCount
                * UInt32(MemoryLayout<Float32>.size)
        }
        frameIndex += Int64(frameCount)
        return noErr
    }
}

private func endToEndInputRenderCallback(
    _ referenceContext: UnsafeMutableRawPointer?,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ outputData: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    _ = actionFlags
    _ = timestamp
    _ = busNumber
    guard let referenceContext else { return kAudio_ParamError }
    let source = Unmanaged<EndToEndInputSignalSource>
        .fromOpaque(referenceContext)
        .takeUnretainedValue()
    return source.render(into: outputData, frameCount: frameCount)
}

private final class AsyncSRCCallbackPipelineHarness {
    private let source: EndToEndInputSignalSource
    private let outputFormat: AVAudioFormat
    private let bufferConfiguration: AsyncSRCBufferConfiguration
    private let scenario: EndToEndScenario
    private var varispeedAudioUnit: AudioUnit?
    private var renderContext: OpaquePointer?
    private var sourceCallbackInstalled = false
    private var varispeedInitialized = false
    private var inputSampleTime: Float64 = 0
    private var outputSampleTime: Float64 = 0

    private init(
        source: EndToEndInputSignalSource,
        outputFormat: AVAudioFormat,
        bufferConfiguration: AsyncSRCBufferConfiguration,
        scenario: EndToEndScenario
    ) {
        self.source = source
        self.outputFormat = outputFormat
        self.bufferConfiguration = bufferConfiguration
        self.scenario = scenario
    }

    static func make(
        scenario: EndToEndScenario = endToEndDefaultScenario,
        includesImpulse: Bool = false
    ) throws -> AsyncSRCCallbackPipelineHarness {
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: scenario.outputSampleRate,
            channels: AVAudioChannelCount(endToEndChannelCount)
        ) else {
            throw EndToEndFailure(
                operation: "Create end-to-end output format",
                status: kAudio_ParamError
            )
        }
        let configuration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: scenario.quantum,
            outputBufferFrames: scenario.quantum,
            inputSampleRate: scenario.inputSampleRate,
            outputSampleRate: scenario.outputSampleRate
        )
        let harness = AsyncSRCCallbackPipelineHarness(
            source: EndToEndInputSignalSource(
                sampleRate: scenario.inputSampleRate,
                includesImpulse: includesImpulse
            ),
            outputFormat: outputFormat,
            bufferConfiguration: configuration,
            scenario: scenario
        )
        do {
            try harness.configure()
            return harness
        } catch {
            harness.disposeWithoutThrowing()
            throw error
        }
    }

    func render(durationSeconds: Double) throws -> [[Float32]] {
        guard durationSeconds > 0, let renderContext else {
            throw EndToEndFailure(
                operation: "Render end-to-end callback pipeline",
                status: kAudio_ParamError
            )
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(scenario.quantum)
        ) else {
            throw EndToEndFailure(
                operation: "Allocate end-to-end output buffer",
                status: kAudio_MemFullError
            )
        }
        outputBuffer.frameLength = AVAudioFrameCount(scenario.quantum)
        let callbackContext = UnsafeMutableRawPointer(renderContext)
        let outputCallbackCount = Int(ceil(
            durationSeconds * scenario.outputSampleRate / Double(scenario.quantum)
        ))
        let inputPeriodSeconds = Double(scenario.quantum)
            / scenario.inputSampleRate
        let outputPeriodSeconds = Double(scenario.quantum)
            / scenario.outputSampleRate
        var nextInputTimeSeconds = 0.0
        var outputTimeSeconds = 0.0
        var renderedChannels = Array(
            repeating: [Float32](),
            count: Int(endToEndChannelCount)
        )
        renderedChannels.indices.forEach {
            renderedChannels[$0].reserveCapacity(
                outputCallbackCount * Int(scenario.quantum)
            )
        }

        for _ in 0..<outputCallbackCount {
            while nextInputTimeSeconds <= outputTimeSeconds {
                var inputFlags: AudioUnitRenderActionFlags = []
                var inputTimestamp = AudioTimeStamp()
                inputTimestamp.mSampleTime = inputSampleTime
                inputTimestamp.mFlags = .sampleTimeValid
                try Self.requireNoError(
                    ScreamBarAsyncSRCInputCallback(
                        callbackContext,
                        &inputFlags,
                        &inputTimestamp,
                        0,
                        scenario.quantum,
                        nil
                    ),
                    operation: "Run end-to-end input callback"
                )
                inputSampleTime += Float64(scenario.quantum)
                nextInputTimeSeconds += inputPeriodSeconds
            }

            var outputFlags: AudioUnitRenderActionFlags = []
            var outputTimestamp = AudioTimeStamp()
            outputTimestamp.mSampleTime = outputSampleTime
            outputTimestamp.mFlags = .sampleTimeValid
            try Self.requireNoError(
                ScreamBarAsyncSRCOutputCallback(
                    callbackContext,
                    &outputFlags,
                    &outputTimestamp,
                    0,
                    scenario.quantum,
                    outputBuffer.mutableAudioBufferList
                ),
                operation: "Run end-to-end output callback"
            )
            if !outputFlags.contains(.unitRenderAction_OutputIsSilence) {
                guard let channelData = outputBuffer.floatChannelData else {
                    throw EndToEndFailure(
                        operation: "Read end-to-end output buffer",
                        status: kAudio_ParamError
                    )
                }
                for channel in renderedChannels.indices {
                    renderedChannels[channel].append(
                        contentsOf: UnsafeBufferPointer(
                            start: channelData[channel],
                            count: Int(scenario.quantum)
                        )
                    )
                }
            }
            outputSampleTime += Float64(scenario.quantum)
            outputTimeSeconds += outputPeriodSeconds
        }
        return renderedChannels
    }

    func metrics() throws -> AsyncSRCMetrics {
        guard let renderContext else {
            throw EndToEndFailure(
                operation: "Read end-to-end metrics",
                status: kAudio_ParamError
            )
        }
        var rawMetrics = ScreamBarAsyncSRCMetrics()
        ScreamBarAsyncSRCCopyMetrics(renderContext, &rawMetrics)
        return AsyncSRCMetrics(rawMetrics)
    }

    func close() throws {
        let failures = cleanup()
        guard failures.isEmpty else {
            throw EndToEndCleanupFailure(failures: failures)
        }
    }

    private func configure() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_Varispeed,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw EndToEndFailure(
                operation: "Find end-to-end Varispeed",
                status: kAudio_ParamError
            )
        }
        var createdAudioUnit: AudioUnit?
        try Self.requireNoError(
            AudioComponentInstanceNew(component, &createdAudioUnit),
            operation: "Create end-to-end Varispeed"
        )
        guard let createdAudioUnit else {
            throw EndToEndFailure(
                operation: "Create end-to-end Varispeed",
                status: kAudio_ParamError
            )
        }
        varispeedAudioUnit = createdAudioUnit

        var maximumFrames = bufferConfiguration.maximumOutputFrames
        try Self.requireNoError(
            AudioUnitSetProperty(
                createdAudioUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maximumFrames,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "Set end-to-end maximum frames"
        )
        var inputFormat = AsyncSRCPlaythrough.makeClientFormat(
            sampleRate: scenario.inputSampleRate,
            channelCount: Int(endToEndChannelCount)
        )
        var outputStreamFormat = AsyncSRCPlaythrough.makeClientFormat(
            sampleRate: scenario.outputSampleRate,
            channelCount: Int(endToEndChannelCount)
        )
        try Self.setFormat(
            &inputFormat,
            on: createdAudioUnit,
            scope: kAudioUnitScope_Input
        )
        try Self.setFormat(
            &outputStreamFormat,
            on: createdAudioUnit,
            scope: kAudioUnitScope_Output
        )
        var renderQuality = UInt32(kRenderQuality_High)
        try Self.requireNoError(
            AudioUnitSetProperty(
                createdAudioUnit,
                kAudioUnitProperty_RenderQuality,
                kAudioUnitScope_Global,
                0,
                &renderQuality,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "Set end-to-end render quality"
        )

        let sourceContext = Unmanaged.passUnretained(source).toOpaque()
        guard let createdContext = ScreamBarAsyncSRCContextCreateWithInputRenderProc(
            endToEndInputRenderCallback,
            sourceContext,
            createdAudioUnit,
            endToEndChannelCount,
            endToEndChannelCount,
            bufferConfiguration.maximumInputFrames,
            bufferConfiguration.maximumOutputFrames,
            bufferConfiguration.ringCapacityFrames,
            bufferConfiguration.targetFillFrames,
            bufferConfiguration.maximumTargetFillFrames,
            bufferConfiguration.maximumReadableFrames,
            scenario.inputSampleRate,
            scenario.outputSampleRate,
            bufferConfiguration.isLowLatency,
            AsyncSRCClockControlPolicy.usesAdaptiveControl(
                inputBufferFrames: scenario.quantum,
                outputBufferFrames: scenario.quantum
            )
        ) else {
            throw EndToEndFailure(
                operation: "Create end-to-end callback context",
                status: kAudio_MemFullError
            )
        }
        renderContext = createdContext

        var sourceCallback = AURenderCallbackStruct(
            inputProc: ScreamBarAsyncSRCSourceCallback,
            inputProcRefCon: UnsafeMutableRawPointer(createdContext)
        )
        try Self.requireNoError(
            AudioUnitSetProperty(
                createdAudioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &sourceCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "Install end-to-end source callback"
        )
        sourceCallbackInstalled = true
        try Self.requireNoError(
            AudioUnitInitialize(createdAudioUnit),
            operation: "Initialize end-to-end Varispeed"
        )
        varispeedInitialized = true
    }

    private func disposeWithoutThrowing() {
        let failures = cleanup()
        if !failures.isEmpty {
            assertionFailure(
                EndToEndCleanupFailure(failures: failures).description
            )
        }
    }

    private func cleanup() -> [EndToEndFailure] {
        var failures: [EndToEndFailure] = []
        if sourceCallbackInstalled, let varispeedAudioUnit {
            var emptyCallback = AURenderCallbackStruct(
                inputProc: nil,
                inputProcRefCon: nil
            )
            let callbackStatus = AudioUnitSetProperty(
                varispeedAudioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &emptyCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            if callbackStatus == noErr {
                sourceCallbackInstalled = false
            } else {
                failures.append(
                    EndToEndFailure(
                        operation: "Remove end-to-end source callback",
                        status: callbackStatus
                    )
                )
            }
        }

        if varispeedInitialized, let varispeedAudioUnit {
            let uninitializeStatus = AudioUnitUninitialize(varispeedAudioUnit)
            if uninitializeStatus == noErr
                || uninitializeStatus == kAudioUnitErr_Uninitialized {
                varispeedInitialized = false
            } else {
                failures.append(
                    EndToEndFailure(
                        operation: "Uninitialize end-to-end Varispeed",
                        status: uninitializeStatus
                    )
                )
            }
        }

        if let varispeedAudioUnit {
            let disposeStatus = AudioComponentInstanceDispose(varispeedAudioUnit)
            if disposeStatus == noErr {
                self.varispeedAudioUnit = nil
                sourceCallbackInstalled = false
                varispeedInitialized = false
            } else {
                failures.append(
                    EndToEndFailure(
                        operation: "Dispose end-to-end Varispeed",
                        status: disposeStatus
                    )
                )
            }
        }

        if !sourceCallbackInstalled, let renderContext {
            ScreamBarAsyncSRCContextDestroy(renderContext)
            self.renderContext = nil
        }
        return failures
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
            operation: "Set end-to-end Varispeed format"
        )
    }

    private static func requireNoError(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw EndToEndFailure(operation: operation, status: status)
        }
    }
}

final class AsyncSRCEndToEndTests: XCTestCase {
    func testCallbacksFIFOAndVarispeedPreserveContinuityMappingAndFidelity() throws {
        let harness = try AsyncSRCCallbackPipelineHarness.make()
        defer { XCTAssertNoThrow(try harness.close()) }

        let channels = try harness.render(durationSeconds: endToEndDurationSeconds)
        let minimumMeasuredFrameCount = Int(
            endToEndMinimumMeasuredSeconds
                * endToEndDefaultScenario.outputSampleRate
        )
        XCTAssertEqual(channels.count, Int(endToEndChannelCount))
        XCTAssertGreaterThanOrEqual(channels[0].count, minimumMeasuredFrameCount)
        XCTAssertEqual(channels[0].count, channels[1].count)

        let left = Array(channels[0].suffix(minimumMeasuredFrameCount))
        let right = Array(channels[1].suffix(minimumMeasuredFrameCount))
        assertMappedTone(
            frequency: 997,
            expectedChannel: left,
            otherChannel: right,
            minimumExpectedAmplitude: 0.20,
            outputSampleRate: endToEndDefaultScenario.outputSampleRate
        )
        assertMappedTone(
            frequency: 4_031,
            expectedChannel: left,
            otherChannel: right,
            minimumExpectedAmplitude: 0.09,
            outputSampleRate: endToEndDefaultScenario.outputSampleRate
        )
        assertMappedTone(
            frequency: 503,
            expectedChannel: right,
            otherChannel: left,
            minimumExpectedAmplitude: 0.17,
            outputSampleRate: endToEndDefaultScenario.outputSampleRate
        )
        assertMappedTone(
            frequency: 7_013,
            expectedChannel: right,
            otherChannel: left,
            minimumExpectedAmplitude: 0.08,
            outputSampleRate: endToEndDefaultScenario.outputSampleRate
        )
        XCTAssertLessThanOrEqual(maximumAbsoluteSample(left), 1)
        XCTAssertLessThanOrEqual(maximumAbsoluteSample(right), 1)
        XCTAssertLessThanOrEqual(longestSilentRun(left: left, right: right), 1)

        assertHealthyMetrics(
            try harness.metrics(),
            scenario: endToEndDefaultScenario
        )
    }

    func testAdditionalConversionScenariosPreservePitchGainSNRAndTiming() throws {
        for scenario in endToEndConversionScenarios {
            try assertConversionQuality(scenario: scenario)
        }
    }

    func testImpulseTraversesOnlyItsMappedChannelWithoutDiscontinuity() throws {
        let impulseHarness = try AsyncSRCCallbackPipelineHarness.make(
            includesImpulse: true
        )
        defer { XCTAssertNoThrow(try impulseHarness.close()) }
        let referenceHarness = try AsyncSRCCallbackPipelineHarness.make()
        defer { XCTAssertNoThrow(try referenceHarness.close()) }

        let impulseChannels = try impulseHarness.render(
            durationSeconds: endToEndDurationSeconds
        )
        let referenceChannels = try referenceHarness.render(
            durationSeconds: endToEndDurationSeconds
        )
        XCTAssertEqual(impulseChannels.map(\.count), referenceChannels.map(\.count))
        let measuredFrameCount = Int(
            endToEndMinimumMeasuredSeconds
                * endToEndDefaultScenario.outputSampleRate
        )
        let leftDifference = zip(
            impulseChannels[0].suffix(measuredFrameCount),
            referenceChannels[0].suffix(measuredFrameCount)
        ).map { $0.0 - $0.1 }
        let rightDifference = zip(
            impulseChannels[1].suffix(measuredFrameCount),
            referenceChannels[1].suffix(measuredFrameCount)
        ).map { $0.0 - $0.1 }

        XCTAssertGreaterThan(maximumAbsoluteSample(leftDifference), 0.10)
        XCTAssertLessThan(maximumAbsoluteSample(rightDifference), 0.000_01)
        XCTAssertGreaterThan(
            leftDifference.lazy.filter { abs($0) > 0.01 }.count,
            10,
            "Periodic impulses were not preserved through the FIFO/SRC path"
        )

        let metrics = try impulseHarness.metrics()
        XCTAssertEqual(metrics.underrunCount, 0)
        XCTAssertEqual(metrics.overflowCount, 0)
        XCTAssertEqual(metrics.resynchronizationCount, 0)
        XCTAssertEqual(metrics.droppedInputFrames, 0)
        XCTAssertFalse(metrics.hasRuntimeErrors)
    }

    private func assertConversionQuality(scenario: EndToEndScenario) throws {
        let harness = try AsyncSRCCallbackPipelineHarness.make(scenario: scenario)
        defer { XCTAssertNoThrow(try harness.close()) }

        let channels = try harness.render(durationSeconds: endToEndDurationSeconds)
        let measuredFrameCount = Int(
            endToEndQualityMeasurementSeconds * scenario.outputSampleRate
        )
        XCTAssertEqual(
            channels.count,
            endToEndChannelTones.count,
            scenario.description
        )
        for channelIndex in channels.indices {
            XCTAssertGreaterThanOrEqual(
                channels[channelIndex].count,
                measuredFrameCount,
                scenario.description
            )
            assertChannelSignalQuality(
                samples: Array(
                    channels[channelIndex].suffix(measuredFrameCount)
                ),
                expectedTones: endToEndChannelTones[channelIndex],
                outputSampleRate: scenario.outputSampleRate,
                context: scenario.description
            )
        }
        assertHealthyMetrics(try harness.metrics(), scenario: scenario)
    }

    private func assertHealthyMetrics(
        _ metrics: AsyncSRCMetrics,
        scenario: EndToEndScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(metrics.capturedFrames, 0, file: file, line: line)
        XCTAssertGreaterThan(metrics.renderedFrames, 0, file: file, line: line)
        XCTAssertEqual(metrics.underrunCount, 0, scenario.description, file: file, line: line)
        XCTAssertEqual(
            metrics.latencyCeilingUnderrunCount,
            0,
            scenario.description,
            file: file,
            line: line
        )
        XCTAssertEqual(metrics.overflowCount, 0, scenario.description, file: file, line: line)
        XCTAssertEqual(
            metrics.resynchronizationCount,
            0,
            scenario.description,
            file: file,
            line: line
        )
        XCTAssertEqual(
            metrics.droppedInputFrames,
            0,
            scenario.description,
            file: file,
            line: line
        )
        XCTAssertFalse(metrics.hasRuntimeErrors, scenario.description, file: file, line: line)
        XCTAssertLessThan(
            metrics.readableFrames,
            metrics.ringCapacityFrames,
            scenario.description,
            file: file,
            line: line
        )
        XCTAssertFalse(
            AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                executionNanoseconds:
                    metrics.maximumInputCallbackExecutionNanoseconds,
                frameCount: metrics.maximumInputCallbackFrames,
                sampleRate: scenario.inputSampleRate
            ),
            "The end-to-end input callback exceeded its real-time frame budget: \(scenario.description)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            AsyncSRCPlaythrough.callbackExecutionExceedsDeadline(
                executionNanoseconds:
                    metrics.maximumOutputCallbackExecutionNanoseconds,
                frameCount: metrics.maximumOutputCallbackFrames,
                sampleRate: scenario.outputSampleRate
            ),
            "The FIFO/Varispeed output callback exceeded its real-time frame budget: \(scenario.description)",
            file: file,
            line: line
        )
    }

    private func assertChannelSignalQuality(
        samples: [Float32],
        expectedTones: [EndToEndTone],
        outputSampleRate: Double,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sampleMean = samples.reduce(0) { partialSum, sample in
            partialSum + Double(sample)
        } / Double(samples.count)
        let fittedTones = expectedTones.map { expectedTone in
            let spectralPeak = spectralPeak(
                samples: samples,
                around: expectedTone.frequency,
                outputSampleRate: outputSampleRate,
                refinesFrequency: true
            )
            let maximumFrequencyError = expectedTone.frequency
                * AsyncSRCClockControlPolicy.maximumPlaybackRateDeviation + 0.5
            XCTAssertLessThanOrEqual(
                abs(spectralPeak.frequency - expectedTone.frequency),
                maximumFrequencyError,
                "Pitch changed for \(expectedTone.frequency) Hz [\(context)]",
                file: file,
                line: line
            )
            let gain = spectralPeak.amplitude / expectedTone.amplitude
            XCTAssertGreaterThanOrEqual(
                gain,
                endToEndMinimumGain,
                "Excessive attenuation for \(expectedTone.frequency) Hz [\(context)]",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                gain,
                endToEndMaximumGain,
                "Excessive gain for \(expectedTone.frequency) Hz [\(context)]",
                file: file,
                line: line
            )
            let projection = projectedTone(
                samples: samples,
                frequency: spectralPeak.frequency,
                outputSampleRate: outputSampleRate,
                sampleMean: sampleMean
            )
            return (
                frequency: spectralPeak.frequency,
                sineAmplitude: projection.sineAmplitude,
                cosineAmplitude: projection.cosineAmplitude
            )
        }

        var signalEnergy = 0.0
        var residualEnergy = 0.0
        for (sampleIndex, sample) in samples.enumerated() {
            var fittedSample = 0.0
            for fittedTone in fittedTones {
                let phase = 2 * Double.pi * fittedTone.frequency
                    * Double(sampleIndex) / outputSampleRate
                fittedSample += fittedTone.sineAmplitude * sin(phase)
                    + fittedTone.cosineAmplitude * cos(phase)
            }
            let centeredSample = Double(sample) - sampleMean
            let residual = centeredSample - fittedSample
            signalEnergy += fittedSample * fittedSample
            residualEnergy += residual * residual
        }
        let signalToNoiseRatioDecibels = 10
            * log10(signalEnergy / residualEnergy)
        XCTAssertTrue(
            signalToNoiseRatioDecibels.isFinite,
            "Non-finite SNR [\(context)]",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            signalToNoiseRatioDecibels,
            endToEndMinimumSignalToNoiseRatioDecibels,
            "Excessive distortion/noise: \(signalToNoiseRatioDecibels) dB [\(context)]",
            file: file,
            line: line
        )
    }

    private func assertMappedTone(
        frequency: Double,
        expectedChannel: [Float32],
        otherChannel: [Float32],
        minimumExpectedAmplitude: Double,
        outputSampleRate: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedPeak = spectralPeak(
            samples: expectedChannel,
            around: frequency,
            outputSampleRate: outputSampleRate
        )
        let leakedPeak = spectralPeak(
            samples: otherChannel,
            around: frequency,
            outputSampleRate: outputSampleRate
        )
        XCTAssertGreaterThanOrEqual(
            expectedPeak.amplitude,
            minimumExpectedAmplitude,
            "\(frequency) Hz lost excessive gain; peak was \(expectedPeak)",
            file: file,
            line: line
        )
        let maximumFrequencyError = frequency
            * AsyncSRCClockControlPolicy.maximumPlaybackRateDeviation + 0.5
        XCTAssertLessThanOrEqual(
            abs(expectedPeak.frequency - frequency),
            maximumFrequencyError,
            "\(frequency) Hz exceeded the clock-control pitch bound",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            expectedPeak.amplitude,
            leakedPeak.amplitude * 8,
            "\(frequency) Hz leaked into the wrong channel",
            file: file,
            line: line
        )
    }

    private func spectralPeak(
        samples: [Float32],
        around frequency: Double,
        outputSampleRate: Double,
        refinesFrequency: Bool = false
    ) -> (frequency: Double, amplitude: Double) {
        let searchRadius = frequency
            * AsyncSRCClockControlPolicy.maximumPlaybackRateDeviation + 0.5
        let sampleMean = samples.reduce(0) { partialSum, sample in
            partialSum + Double(sample)
        } / Double(samples.count)
        var coarsePeak = (frequency: frequency, energy: 0.0)
        for candidateFrequency in stride(
            from: frequency - searchRadius,
            through: frequency + searchRadius,
            by: 0.25
        ) {
            let projection = projectedTone(
                samples: samples,
                frequency: candidateFrequency,
                outputSampleRate: outputSampleRate,
                sampleMean: sampleMean
            )
            let energy = projection.sineAmplitude * projection.sineAmplitude
                + projection.cosineAmplitude * projection.cosineAmplitude
            if energy > coarsePeak.energy {
                coarsePeak = (candidateFrequency, energy)
            }
        }
        guard refinesFrequency else {
            return (
                frequency: coarsePeak.frequency,
                amplitude: sqrt(coarsePeak.energy)
            )
        }
        let refinedFrequency = bestFittingFrequency(
            samples: samples,
            sampleMean: sampleMean,
            lowerBound: max(
                frequency - searchRadius,
                coarsePeak.frequency - 0.25
            ),
            upperBound: min(
                frequency + searchRadius,
                coarsePeak.frequency + 0.25
            ),
            outputSampleRate: outputSampleRate
        )
        let projection = projectedTone(
            samples: samples,
            frequency: refinedFrequency,
            outputSampleRate: outputSampleRate,
            sampleMean: sampleMean
        )
        return (
            frequency: refinedFrequency,
            amplitude: hypot(
                projection.sineAmplitude,
                projection.cosineAmplitude
            )
        )
    }

    private func bestFittingFrequency(
        samples: [Float32],
        sampleMean: Double,
        lowerBound: Double,
        upperBound: Double,
        outputSampleRate: Double
    ) -> Double {
        let goldenRatio = (sqrt(5.0) - 1) / 2
        var currentLowerBound = lowerBound
        var currentUpperBound = upperBound
        var lowerCandidate = currentUpperBound
            - goldenRatio * (currentUpperBound - currentLowerBound)
        var upperCandidate = currentLowerBound
            + goldenRatio * (currentUpperBound - currentLowerBound)
        var lowerEnergy = projectedToneEnergy(
            samples: samples,
            frequency: lowerCandidate,
            outputSampleRate: outputSampleRate,
            sampleMean: sampleMean
        )
        var upperEnergy = projectedToneEnergy(
            samples: samples,
            frequency: upperCandidate,
            outputSampleRate: outputSampleRate,
            sampleMean: sampleMean
        )

        for _ in 0..<32 {
            if lowerEnergy < upperEnergy {
                currentLowerBound = lowerCandidate
                lowerCandidate = upperCandidate
                lowerEnergy = upperEnergy
                upperCandidate = currentLowerBound
                    + goldenRatio * (currentUpperBound - currentLowerBound)
                upperEnergy = projectedToneEnergy(
                    samples: samples,
                    frequency: upperCandidate,
                    outputSampleRate: outputSampleRate,
                    sampleMean: sampleMean
                )
            } else {
                currentUpperBound = upperCandidate
                upperCandidate = lowerCandidate
                upperEnergy = lowerEnergy
                lowerCandidate = currentUpperBound
                    - goldenRatio * (currentUpperBound - currentLowerBound)
                lowerEnergy = projectedToneEnergy(
                    samples: samples,
                    frequency: lowerCandidate,
                    outputSampleRate: outputSampleRate,
                    sampleMean: sampleMean
                )
            }
        }
        return (currentLowerBound + currentUpperBound) / 2
    }

    private func projectedToneEnergy(
        samples: [Float32],
        frequency: Double,
        outputSampleRate: Double,
        sampleMean: Double
    ) -> Double {
        let projection = projectedTone(
            samples: samples,
            frequency: frequency,
            outputSampleRate: outputSampleRate,
            sampleMean: sampleMean
        )
        return projection.sineAmplitude * projection.sineAmplitude
            + projection.cosineAmplitude * projection.cosineAmplitude
    }

    private func projectedTone(
        samples: [Float32],
        frequency: Double,
        outputSampleRate: Double,
        sampleMean: Double
    ) -> (sineAmplitude: Double, cosineAmplitude: Double) {
        let angularFrequency = 2 * Double.pi * frequency / outputSampleRate
        var sineProjection = 0.0
        var cosineProjection = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = angularFrequency * Double(index)
            let centeredSample = Double(sample) - sampleMean
            sineProjection += centeredSample * sin(phase)
            cosineProjection += centeredSample * cos(phase)
        }
        return (
            sineAmplitude: 2 * sineProjection / Double(samples.count),
            cosineAmplitude: 2 * cosineProjection / Double(samples.count)
        )
    }

    private func maximumAbsoluteSample(_ samples: [Float32]) -> Float32 {
        samples.lazy.map(abs).max() ?? 0
    }

    private func longestSilentRun(left: [Float32], right: [Float32]) -> Int {
        var longestRun = 0
        var currentRun = 0
        for (leftSample, rightSample) in zip(left, right) {
            if leftSample == 0, rightSample == 0 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return longestRun
    }
}
