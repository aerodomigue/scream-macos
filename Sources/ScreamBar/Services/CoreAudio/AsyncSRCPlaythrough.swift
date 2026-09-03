import AudioToolbox
import CoreAudio
import Foundation
import ScreamBarCoreAudioRT
import os

private let asyncSRCLogger = Logger(
    subsystem: "com.screambar.app",
    category: "AsyncSRCPlaythrough"
)

enum AsyncSRCPlaythroughTopology {
    static let inputElement: AudioUnitElement = 1
    static let outputElement: AudioUnitElement = 0
    static let inputEnableScope: AudioUnitScope = kAudioUnitScope_Input
    static let outputEnableScope: AudioUnitScope = kAudioUnitScope_Output
}

enum AsyncSRCClockControlPolicy {
    static let maximumAdaptiveQuantum: UInt32 = 128
    static var maximumPlaybackRateDeviation: Double {
        ScreamBarAsyncSRCMaximumPlaybackRateDeviation()
    }

    static func usesAdaptiveControl(
        inputBufferFrames: UInt32?,
        outputBufferFrames: UInt32?
    ) -> Bool {
        let inputQuantum = inputBufferFrames
            ?? AsyncSRCBufferSizing.defaultDeviceQuantum
        let outputQuantum = outputBufferFrames
            ?? AsyncSRCBufferSizing.defaultDeviceQuantum
        return inputQuantum <= maximumAdaptiveQuantum
            && outputQuantum <= maximumAdaptiveQuantum
    }
}

enum AsyncSRCAudioUnitRole: String {
    case inputAUHAL = "input AUHAL"
    case outputAUHAL = "output AUHAL"
    case varispeed = "Varispeed"
}

enum AsyncSRCCallbackRole: String {
    case input = "input"
    case output = "output"
    case varispeedSource = "Varispeed source"
}

struct AsyncSRCAudioUnitOperations {
    let start: (AudioUnit, AsyncSRCAudioUnitRole) -> OSStatus
    let stop: (AudioUnit, AsyncSRCAudioUnitRole) -> OSStatus
    let clearCallback: (AudioUnit, AsyncSRCCallbackRole) -> OSStatus
    let uninitialize: (AudioUnit, AsyncSRCAudioUnitRole) -> OSStatus
    let dispose: (AudioUnit, AsyncSRCAudioUnitRole) -> OSStatus
    let flushRenderMetrics: (OpaquePointer) -> Void
    let copyRenderMetrics: (
        OpaquePointer,
        UnsafeMutablePointer<ScreamBarAsyncSRCMetrics>
    ) -> Void
    let destroyRenderContext: (OpaquePointer) -> Void

    static let live = AsyncSRCAudioUnitOperations(
        start: { audioUnit, _ in AudioOutputUnitStart(audioUnit) },
        stop: { audioUnit, _ in AudioOutputUnitStop(audioUnit) },
        clearCallback: { audioUnit, role in
            var emptyCallback = AURenderCallbackStruct(
                inputProc: nil,
                inputProcRefCon: nil
            )
            switch role {
            case .input:
                return AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &emptyCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                )
            case .output:
                return AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    AsyncSRCPlaythroughTopology.outputElement,
                    &emptyCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                )
            case .varispeedSource:
                return AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &emptyCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                )
            }
        },
        uninitialize: { audioUnit, _ in AudioUnitUninitialize(audioUnit) },
        dispose: { audioUnit, _ in AudioComponentInstanceDispose(audioUnit) },
        flushRenderMetrics: ScreamBarAsyncSRCFlushMetrics,
        copyRenderMetrics: ScreamBarAsyncSRCCopyMetrics,
        destroyRenderContext: ScreamBarAsyncSRCContextDestroy
    )
}

struct AsyncSRCMeasuredLatency: Equatable {
    let estimatedSeconds: Double
    let maximumSeconds: Double
    let isLowLatency: Bool
}

struct AsyncSRCMetrics: Equatable, Sendable {
    let capturedFrames: UInt64
    let renderedFrames: UInt64
    let primingSilenceFrames: UInt64
    let droppedInputFrames: UInt64
    let underrunCount: UInt64
    let latencyCeilingUnderrunCount: UInt64
    let overflowCount: UInt64
    let resynchronizationCount: UInt64
    let startupTrimCount: UInt64
    let startupTrimmedFrames: UInt64
    let inputRenderErrorCount: UInt64
    let outputRenderErrorCount: UInt64
    let rateParameterErrorCount: UInt64
    let inputCallbackDeadlineMissCount: UInt64
    let outputCallbackDeadlineMissCount: UInt64
    let fifoFillSampleCount: UInt64
    let fifoFillFrameSum: UInt64
    let playbackRateAdjustmentCount: UInt64
    let latencyCeilingOverflowCount: UInt64
    let inputCallbackFrameLimitExceededCount: UInt64
    let outputCallbackFrameLimitExceededCount: UInt64
    let readableFrames: UInt32
    let targetFillFrames: UInt32
    let maximumTargetFillFrames: UInt32
    let ringCapacityFrames: UInt32
    let maximumInputCallbackFrames: UInt32
    let maximumOutputCallbackFrames: UInt32
    let maximumSourceCallbackFrames: UInt32
    let maximumSourceFramesPerOutputCallback: UInt32
    let lastSourceRequestedFrames: UInt32
    let lastSourceReadableFrames: UInt32
    let underrunSourceRequestedFrames: UInt32
    let underrunSourceReadableFrames: UInt32
    let minimumFIFOFillFrames: UInt32
    let maximumFIFOFillFrames: UInt32
    let maximumInputCallbackGapNanoseconds: UInt64
    let maximumOutputCallbackGapNanoseconds: UInt64
    let maximumInputCallbackExecutionNanoseconds: UInt64
    let maximumOutputCallbackExecutionNanoseconds: UInt64
    let playbackRate: Double
    let minimumPlaybackRate: Double?
    let maximumPlaybackRate: Double?
    let maximumPlaybackRateDeviation: Double
    let telemetrySaturated: Bool
    let lastInputStatus: OSStatus
    let lastOutputStatus: OSStatus

    var hasRuntimeErrors: Bool {
        inputRenderErrorCount > 0
            || outputRenderErrorCount > 0
            || rateParameterErrorCount > 0
            || inputCallbackDeadlineMissCount > 0
            || outputCallbackDeadlineMissCount > 0
            || telemetrySaturated
            || latencyCeilingOverflowCount > 0
            || inputCallbackFrameLimitExceededCount > 0
            || outputCallbackFrameLimitExceededCount > 0
    }

    var hasMissedCallbackDeadline: Bool {
        inputCallbackDeadlineMissCount > 0
            || outputCallbackDeadlineMissCount > 0
    }

    var meanFIFOFillFrames: Double {
        guard fifoFillSampleCount > 0 else { return 0 }
        return Double(fifoFillFrameSum) / Double(fifoFillSampleCount)
    }

    init(_ metrics: ScreamBarAsyncSRCMetrics) {
        capturedFrames = metrics.captured_frames
        renderedFrames = metrics.rendered_frames
        primingSilenceFrames = metrics.priming_silence_frames
        droppedInputFrames = metrics.dropped_input_frames
        underrunCount = metrics.underrun_count
        latencyCeilingUnderrunCount =
            metrics.latency_ceiling_underrun_count
        overflowCount = metrics.overflow_count
        resynchronizationCount = metrics.resynchronization_count
        startupTrimCount = metrics.startup_trim_count
        startupTrimmedFrames = metrics.startup_trimmed_frames
        inputRenderErrorCount = metrics.input_render_error_count
        outputRenderErrorCount = metrics.output_render_error_count
        rateParameterErrorCount = metrics.rate_parameter_error_count
        inputCallbackDeadlineMissCount =
            metrics.input_callback_deadline_miss_count
        outputCallbackDeadlineMissCount =
            metrics.output_callback_deadline_miss_count
        fifoFillSampleCount = metrics.fifo_fill_sample_count
        fifoFillFrameSum = metrics.fifo_fill_frame_sum
        playbackRateAdjustmentCount = metrics.playback_rate_adjustment_count
        latencyCeilingOverflowCount = metrics.latency_ceiling_overflow_count
        inputCallbackFrameLimitExceededCount =
            metrics.input_callback_frame_limit_exceeded_count
        outputCallbackFrameLimitExceededCount =
            metrics.output_callback_frame_limit_exceeded_count
        readableFrames = metrics.readable_frames
        targetFillFrames = metrics.target_fill_frames
        maximumTargetFillFrames = metrics.maximum_target_fill_frames
        ringCapacityFrames = metrics.ring_capacity_frames
        maximumInputCallbackFrames = metrics.maximum_input_callback_frames
        maximumOutputCallbackFrames = metrics.maximum_output_callback_frames
        maximumSourceCallbackFrames = metrics.maximum_source_callback_frames
        maximumSourceFramesPerOutputCallback =
            metrics.maximum_source_frames_per_output_callback
        lastSourceRequestedFrames = metrics.last_source_requested_frames
        lastSourceReadableFrames = metrics.last_source_readable_frames
        underrunSourceRequestedFrames = metrics.underrun_source_requested_frames
        underrunSourceReadableFrames = metrics.underrun_source_readable_frames
        minimumFIFOFillFrames = metrics.minimum_fifo_fill_frames
        maximumFIFOFillFrames = metrics.maximum_fifo_fill_frames
        maximumInputCallbackGapNanoseconds = AudioConvertHostTimeToNanos(
            metrics.maximum_input_callback_host_time_gap
        )
        maximumOutputCallbackGapNanoseconds = AudioConvertHostTimeToNanos(
            metrics.maximum_output_callback_host_time_gap
        )
        maximumInputCallbackExecutionNanoseconds = AudioConvertHostTimeToNanos(
            metrics.maximum_input_callback_execution_host_time
        )
        maximumOutputCallbackExecutionNanoseconds = AudioConvertHostTimeToNanos(
            metrics.maximum_output_callback_execution_host_time
        )
        playbackRate = metrics.playback_rate
        minimumPlaybackRate = metrics.minimum_playback_rate > 0
            ? metrics.minimum_playback_rate
            : nil
        maximumPlaybackRate = metrics.maximum_playback_rate > 0
            ? metrics.maximum_playback_rate
            : nil
        maximumPlaybackRateDeviation = metrics.maximum_playback_rate_deviation
        telemetrySaturated = metrics.telemetry_saturated
        lastInputStatus = metrics.last_input_status
        lastOutputStatus = metrics.last_output_status
    }
}

struct AsyncSRCPlaythroughRetainedConstructionFailure: Error {
    let primaryError: Error
    let playthrough: AsyncSRCPlaythrough
    let cleanupFailures: [String]
}

final class AsyncSRCPlaythrough: CoreAudioRouteTransport {
    private static let maximumContextRebuildCount = 2

    private var inputAudioUnit: AudioUnit?
    private var outputAudioUnit: AudioUnit?
    private var varispeedAudioUnit: AudioUnit?
    private var renderContext: OpaquePointer?
    private var inputInitialized = false
    private var outputInitialized = false
    private var varispeedInitialized = false
    private var inputStarted = false
    private var outputStarted = false
    private var inputCallbackInstalled = false
    private var outputCallbackInstalled = false
    private var sourceCallbackInstalled = false
    private var finalMetrics: AsyncSRCMetrics?
    private(set) var converterLatencySeconds: Double = 0
    private(set) var estimatedApplicationLatencySeconds: Double = 0
    private(set) var maximumApplicationLatencySeconds: Double = 0
    private(set) var isLowLatency = false
    private var inputSampleRate: Double = 0
    private var outputSampleRate: Double = 0
    private var configuredInputQuantumFrames: UInt32 = 0
    private let audioUnitOperations: AsyncSRCAudioUnitOperations

    private init(
        audioUnitOperations: AsyncSRCAudioUnitOperations = .live
    ) {
        self.audioUnitOperations = audioUnitOperations
    }

    init(
        testingInputAudioUnit: AudioUnit?,
        testingOutputAudioUnit: AudioUnit?,
        testingVarispeedAudioUnit: AudioUnit?,
        renderContext: OpaquePointer?,
        inputInitialized: Bool,
        outputInitialized: Bool,
        varispeedInitialized: Bool,
        inputStarted: Bool,
        outputStarted: Bool,
        testingInputCallbackInstalled: Bool,
        testingOutputCallbackInstalled: Bool,
        testingSourceCallbackInstalled: Bool,
        audioUnitOperations: AsyncSRCAudioUnitOperations
    ) {
        inputAudioUnit = testingInputAudioUnit
        outputAudioUnit = testingOutputAudioUnit
        varispeedAudioUnit = testingVarispeedAudioUnit
        self.renderContext = renderContext
        self.inputInitialized = inputInitialized
        self.outputInitialized = outputInitialized
        self.varispeedInitialized = varispeedInitialized
        self.inputStarted = inputStarted
        self.outputStarted = outputStarted
        inputCallbackInstalled = testingInputCallbackInstalled
            && testingInputAudioUnit != nil
        outputCallbackInstalled = testingOutputCallbackInstalled
            && testingOutputAudioUnit != nil
        sourceCallbackInstalled = testingSourceCallbackInstalled
            && testingVarispeedAudioUnit != nil
        self.audioUnitOperations = audioUnitOperations
    }

    var isFullyDisposed: Bool {
        inputAudioUnit == nil
            && outputAudioUnit == nil
            && varispeedAudioUnit == nil
            && renderContext == nil
    }

    var metrics: AsyncSRCMetrics? {
        guard let renderContext else { return finalMetrics }
        var rawMetrics = ScreamBarAsyncSRCMetrics()
        audioUnitOperations.copyRenderMetrics(renderContext, &rawMetrics)
        return AsyncSRCMetrics(rawMetrics)
    }

    var currentApplicationLatencySeconds: Double {
        guard inputSampleRate > 0, let metrics else {
            return estimatedApplicationLatencySeconds
        }
        return AsyncSRCBufferSizing.applicationLatencySeconds(
            targetFillFrames: metrics.targetFillFrames,
            configuredInputQuantumFrames: configuredInputQuantumFrames,
            observedInputQuantumFrames: metrics.maximumInputCallbackFrames,
            readableFrames: metrics.readableFrames,
            inputSampleRate: inputSampleRate,
            converterLatencySeconds: converterLatencySeconds
        )
    }

    var hasMissedCallbackDeadline: Bool {
        metrics?.hasMissedCallbackDeadline ?? false
    }

    static func callbackExecutionExceedsDeadline(
        executionNanoseconds: UInt64,
        frameCount: UInt32,
        sampleRate: Double
    ) -> Bool {
        guard executionNanoseconds > 0,
              frameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return false
        }
        let deadlineNanoseconds = Double(frameCount) / sampleRate
            * 1_000_000_000
        return Double(executionNanoseconds) >= deadlineNanoseconds
    }

    static func measuredLatency(
        bufferConfiguration: AsyncSRCBufferConfiguration,
        configuredInputQuantumFrames: UInt32,
        inputSampleRate: Double,
        converterLatencySeconds: Double
    ) -> AsyncSRCMeasuredLatency {
        let estimatedSeconds = AsyncSRCBufferSizing.applicationLatencySeconds(
            targetFillFrames: bufferConfiguration.targetFillFrames,
            configuredInputQuantumFrames: configuredInputQuantumFrames,
            observedInputQuantumFrames: 0,
            readableFrames: 0,
            inputSampleRate: inputSampleRate,
            converterLatencySeconds: converterLatencySeconds
        )
        let maximumSeconds = Double(bufferConfiguration.maximumReadableFrames)
            / inputSampleRate + converterLatencySeconds
        return AsyncSRCMeasuredLatency(
            estimatedSeconds: estimatedSeconds,
            maximumSeconds: maximumSeconds,
            isLowLatency: bufferConfiguration.isLowLatency
                && maximumSeconds
                <= AsyncSRCBufferSizing.maximumApplicationLatencySeconds
        )
    }

    static func requiresContextRebuild(
        current: AsyncSRCBufferConfiguration,
        measured: AsyncSRCBufferConfiguration
    ) -> Bool {
        current.maximumInputFrames != measured.maximumInputFrames
            || current.maximumOutputFrames != measured.maximumOutputFrames
            || current.ringCapacityFrames != measured.ringCapacityFrames
            || current.targetFillFrames != measured.targetFillFrames
            || current.maximumTargetFillFrames
                != measured.maximumTargetFillFrames
            || current.maximumReadableFrames != measured.maximumReadableFrames
            || current.isLowLatency != measured.isLowLatency
    }

    static func make(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        inputChannelCount: Int,
        outputChannelCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double,
        inputBufferFrames: UInt32?,
        outputBufferFrames: UInt32?
    ) throws -> AsyncSRCPlaythrough {
        guard inputChannelCount > 0, outputChannelCount > 0 else {
            throw AUHALSetupFailure(stage: .channelMapping, status: kAudio_ParamError)
        }
        let playthrough = AsyncSRCPlaythrough()
        do {
            playthrough.inputAudioUnit = try makeAudioUnit(
                componentType: kAudioUnitType_Output,
                componentSubtype: kAudioUnitSubType_HALOutput
            )
            playthrough.outputAudioUnit = try makeAudioUnit(
                componentType: kAudioUnitType_Output,
                componentSubtype: kAudioUnitSubType_HALOutput
            )
            playthrough.varispeedAudioUnit = try makeAudioUnit(
                componentType: kAudioUnitType_FormatConverter,
                componentSubtype: kAudioUnitSubType_Varispeed
            )
            try playthrough.configure(
                inputDeviceID: inputDeviceID,
                outputDeviceID: outputDeviceID,
                inputChannelCount: inputChannelCount,
                outputChannelCount: outputChannelCount,
                inputSampleRate: inputSampleRate,
                outputSampleRate: outputSampleRate,
                inputBufferFrames: inputBufferFrames,
                outputBufferFrames: outputBufferFrames
            )
            return playthrough
        } catch {
            let cleanupFailures = playthrough.stopAndDispose()
            if !playthrough.isFullyDisposed {
                throw AsyncSRCPlaythroughRetainedConstructionFailure(
                    primaryError: error,
                    playthrough: playthrough,
                    cleanupFailures: cleanupFailures
                )
            }
            throw error
        }
    }

    func start() throws {
        guard let inputAudioUnit, let outputAudioUnit,
              inputInitialized, outputInitialized, varispeedInitialized else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        if inputStarted && outputStarted {
            return
        }

        var startedOutputInThisCall = false
        if !outputStarted {
            asyncSRCLogger.debug("Direct SRC: starting output AUHAL")
            let outputStartStatus = audioUnitOperations.start(
                outputAudioUnit,
                .outputAUHAL
            )
            guard outputStartStatus == noErr else {
                throw AUHALSetupFailure(
                    stage: .outputIO,
                    status: outputStartStatus
                )
            }
            outputStarted = true
            startedOutputInThisCall = true
            asyncSRCLogger.debug("Direct SRC: output AUHAL started")
        }

        guard !inputStarted else { return }
        asyncSRCLogger.debug("Direct SRC: starting input AUHAL")
        let inputStartStatus = audioUnitOperations.start(
            inputAudioUnit,
            .inputAUHAL
        )
        guard inputStartStatus == noErr else {
            if startedOutputInThisCall {
                asyncSRCLogger.debug(
                    "Direct SRC: rolling back output AUHAL start"
                )
                let outputStopStatus = audioUnitOperations.stop(
                    outputAudioUnit,
                    .outputAUHAL
                )
                if outputStopStatus == noErr {
                    outputStarted = false
                    asyncSRCLogger.debug(
                        "Direct SRC: output AUHAL start rolled back"
                    )
                } else {
                    asyncSRCLogger.error(
                        "Direct SRC: rollback output stop failed: \(CoreAudioBackendFailure.statusDescription(for: outputStopStatus), privacy: .public)"
                    )
                }
            }
            throw AUHALSetupFailure(stage: .inputIO, status: inputStartStatus)
        }
        inputStarted = true
        asyncSRCLogger.debug("Direct SRC: input AUHAL started")
    }

    func stopAndDispose() -> [String] {
        var failures: [String] = []

        if inputStarted, let inputAudioUnit {
            asyncSRCLogger.debug("Direct SRC: stopping input AUHAL")
            let status = audioUnitOperations.stop(inputAudioUnit, .inputAUHAL)
            if status == noErr {
                inputStarted = false
                asyncSRCLogger.debug("Direct SRC: input AUHAL stopped")
            } else {
                failures.append(
                    teardownFailure(stage: "stopping input AUHAL", status: status)
                )
            }
        }
        if outputStarted, let outputAudioUnit {
            asyncSRCLogger.debug("Direct SRC: stopping output AUHAL")
            let status = audioUnitOperations.stop(outputAudioUnit, .outputAUHAL)
            if status == noErr {
                outputStarted = false
                asyncSRCLogger.debug("Direct SRC: output AUHAL stopped")
            } else {
                failures.append(
                    teardownFailure(stage: "stopping output AUHAL", status: status)
                )
            }
        }
        if !outputStarted, let renderContext {
            audioUnitOperations.flushRenderMetrics(renderContext)
            var rawMetrics = ScreamBarAsyncSRCMetrics()
            audioUnitOperations.copyRenderMetrics(renderContext, &rawMetrics)
            finalMetrics = AsyncSRCMetrics(rawMetrics)
        }

        failures.append(contentsOf: clearCallbacksForStoppedAudioUnits())

        if !inputStarted, inputInitialized, let inputAudioUnit {
            asyncSRCLogger.debug("Direct SRC: uninitializing input AUHAL")
            let status = audioUnitOperations.uninitialize(
                inputAudioUnit,
                .inputAUHAL
            )
            if status == noErr || status == kAudioUnitErr_Uninitialized {
                inputInitialized = false
                asyncSRCLogger.debug("Direct SRC: input AUHAL uninitialized")
            } else {
                failures.append(
                    teardownFailure(
                        stage: "uninitializing input AUHAL",
                        status: status
                    )
                )
            }
        }
        if !outputStarted, outputInitialized, let outputAudioUnit {
            asyncSRCLogger.debug("Direct SRC: uninitializing output AUHAL")
            let status = audioUnitOperations.uninitialize(
                outputAudioUnit,
                .outputAUHAL
            )
            if status == noErr || status == kAudioUnitErr_Uninitialized {
                outputInitialized = false
                asyncSRCLogger.debug("Direct SRC: output AUHAL uninitialized")
            } else {
                failures.append(
                    teardownFailure(
                        stage: "uninitializing output AUHAL",
                        status: status
                    )
                )
            }
        }
        if !outputStarted, varispeedInitialized, let varispeedAudioUnit {
            asyncSRCLogger.debug("Direct SRC: uninitializing Varispeed")
            let status = audioUnitOperations.uninitialize(
                varispeedAudioUnit,
                .varispeed
            )
            if status == noErr || status == kAudioUnitErr_Uninitialized {
                varispeedInitialized = false
                asyncSRCLogger.debug("Direct SRC: Varispeed uninitialized")
            } else {
                failures.append(
                    teardownFailure(
                        stage: "uninitializing Varispeed",
                        status: status
                    )
                )
            }
        }

        if !inputStarted, let inputAudioUnit {
            if let failure = disposeAudioUnit(
                inputAudioUnit,
                role: .inputAUHAL
            ) {
                failures.append(failure)
            } else {
                self.inputAudioUnit = nil
                inputInitialized = false
                inputCallbackInstalled = false
            }
        }
        if !outputStarted, let outputAudioUnit {
            if let failure = disposeAudioUnit(
                outputAudioUnit,
                role: .outputAUHAL
            ) {
                failures.append(failure)
            } else {
                self.outputAudioUnit = nil
                outputInitialized = false
                outputCallbackInstalled = false
            }
        }
        if !outputStarted, let varispeedAudioUnit {
            if let failure = disposeAudioUnit(
                varispeedAudioUnit,
                role: .varispeed
            ) {
                failures.append(failure)
            } else {
                self.varispeedAudioUnit = nil
                varispeedInitialized = false
                sourceCallbackInstalled = false
            }
        }

        if callbacksAreInvalidated, let renderContext {
            asyncSRCLogger.debug("Direct SRC: releasing render context")
            audioUnitOperations.destroyRenderContext(renderContext)
            self.renderContext = nil
            asyncSRCLogger.debug("Direct SRC: render context released")
        } else if renderContext != nil {
            asyncSRCLogger.error(
                "Direct SRC: retaining render context because at least one callback remains installed"
            )
        }
        if isFullyDisposed {
            asyncSRCLogger.debug("Direct SRC: teardown complete")
        } else {
            asyncSRCLogger.error(
                "Direct SRC: teardown incomplete; CoreAudio resources retained for retry"
            )
        }
        return failures
    }

    private static func makeAudioUnit(
        componentType: OSType,
        componentSubtype: OSType
    ) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AUHALCreationFailure(status: kAudio_ParamError)
        }
        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            throw AUHALCreationFailure(status: status)
        }
        return audioUnit
    }

    private func configure(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        inputChannelCount: Int,
        outputChannelCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double,
        inputBufferFrames: UInt32?,
        outputBufferFrames: UInt32?
    ) throws {
        guard let inputAudioUnit, let outputAudioUnit, let varispeedAudioUnit else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        let initialBufferConfiguration = AsyncSRCBufferSizing.configuration(
            inputBufferFrames: inputBufferFrames,
            outputBufferFrames: outputBufferFrames,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )

        try configureInputAUHAL(
            inputAudioUnit,
            deviceID: inputDeviceID,
            channelCount: inputChannelCount,
            sampleRate: inputSampleRate,
            maximumFrames: initialBufferConfiguration.maximumInputFrames
        )
        try configureOutputAUHAL(
            outputAudioUnit,
            deviceID: outputDeviceID,
            channelCount: outputChannelCount,
            sampleRate: outputSampleRate,
            maximumFrames: initialBufferConfiguration.maximumOutputFrames
        )
        try configureVarispeed(
            varispeedAudioUnit,
            channelCount: outputChannelCount,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate,
            maximumFrames: initialBufferConfiguration.maximumOutputFrames
        )
        let usesAdaptiveClockControl =
            AsyncSRCClockControlPolicy.usesAdaptiveControl(
                inputBufferFrames: inputBufferFrames,
                outputBufferFrames: outputBufferFrames
            )
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        configuredInputQuantumFrames = inputBufferFrames
            ?? AsyncSRCBufferSizing.defaultDeviceQuantum

        var activeBufferConfiguration = initialBufferConfiguration
        try buildContextAndInitializeAudioUnits(
            bufferConfiguration: activeBufferConfiguration,
            inputAudioUnit: inputAudioUnit,
            outputAudioUnit: outputAudioUnit,
            varispeedAudioUnit: varispeedAudioUnit,
            inputChannelCount: inputChannelCount,
            outputChannelCount: outputChannelCount,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate,
            usesAdaptiveClockControl: usesAdaptiveClockControl
        )

        var contextRebuildCount = 0
        while true {
            let initializedConverterLatencySeconds = try readConverterLatency(
                from: varispeedAudioUnit
            )
            let measuredBufferConfiguration =
                AsyncSRCBufferSizing.configuration(
                    inputBufferFrames: inputBufferFrames,
                    outputBufferFrames: outputBufferFrames,
                    inputSampleRate: inputSampleRate,
                    outputSampleRate: outputSampleRate,
                    converterLatencySeconds:
                        initializedConverterLatencySeconds
                )
            if Self.requiresContextRebuild(
                current: activeBufferConfiguration,
                measured: measuredBufferConfiguration
            ) {
                guard contextRebuildCount < Self.maximumContextRebuildCount else {
                    throw AUHALSetupFailure(
                        stage: .sampleRateConverter,
                        status: kAudio_ParamError
                    )
                }
                asyncSRCLogger.debug(
                    "Direct SRC: rebuilding render context for initialized Varispeed latency \(initializedConverterLatencySeconds * 1_000, privacy: .public) ms"
                )
                try releaseContextForRebuild(
                    inputAudioUnit: inputAudioUnit,
                    outputAudioUnit: outputAudioUnit,
                    varispeedAudioUnit: varispeedAudioUnit
                )
                activeBufferConfiguration = measuredBufferConfiguration
                try buildContextAndInitializeAudioUnits(
                    bufferConfiguration: activeBufferConfiguration,
                    inputAudioUnit: inputAudioUnit,
                    outputAudioUnit: outputAudioUnit,
                    varispeedAudioUnit: varispeedAudioUnit,
                    inputChannelCount: inputChannelCount,
                    outputChannelCount: outputChannelCount,
                    inputSampleRate: inputSampleRate,
                    outputSampleRate: outputSampleRate,
                    usesAdaptiveClockControl: usesAdaptiveClockControl
                )
                contextRebuildCount += 1
                continue
            }

            let measuredLatency = Self.measuredLatency(
                bufferConfiguration: activeBufferConfiguration,
                configuredInputQuantumFrames: configuredInputQuantumFrames,
                inputSampleRate: inputSampleRate,
                converterLatencySeconds: initializedConverterLatencySeconds
            )
            guard measuredLatency.estimatedSeconds.isFinite,
                  measuredLatency.maximumSeconds.isFinite,
                  measuredLatency.estimatedSeconds
                    <= measuredLatency.maximumSeconds else {
                throw AUHALSetupFailure(
                    stage: .sampleRateConverter,
                    status: kAudio_ParamError
                )
            }
            converterLatencySeconds = initializedConverterLatencySeconds
            estimatedApplicationLatencySeconds = measuredLatency.estimatedSeconds
            maximumApplicationLatencySeconds = measuredLatency.maximumSeconds
            isLowLatency = measuredLatency.isLowLatency
            asyncSRCLogger.debug(
                "Direct SRC: initialized Varispeed latency is \(initializedConverterLatencySeconds * 1_000, privacy: .public) ms; application ceiling is \(measuredLatency.maximumSeconds * 1_000, privacy: .public) ms"
            )
            return
        }
    }

    private func buildContextAndInitializeAudioUnits(
        bufferConfiguration: AsyncSRCBufferConfiguration,
        inputAudioUnit: AudioUnit,
        outputAudioUnit: AudioUnit,
        varispeedAudioUnit: AudioUnit,
        inputChannelCount: Int,
        outputChannelCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double,
        usesAdaptiveClockControl: Bool
    ) throws {
        guard renderContext == nil, callbacksAreInvalidated,
              !inputInitialized, !outputInitialized,
              !varispeedInitialized else {
            throw AUHALSetupFailure(
                stage: .sampleRateConverter,
                status: kAudio_ParamError
            )
        }
        guard let context = ScreamBarAsyncSRCContextCreate(
            inputAudioUnit,
            varispeedAudioUnit,
            UInt32(inputChannelCount),
            UInt32(outputChannelCount),
            bufferConfiguration.maximumInputFrames,
            bufferConfiguration.maximumOutputFrames,
            bufferConfiguration.ringCapacityFrames,
            bufferConfiguration.targetFillFrames,
            bufferConfiguration.maximumTargetFillFrames,
            bufferConfiguration.maximumReadableFrames,
            inputSampleRate,
            outputSampleRate,
            bufferConfiguration.isLowLatency,
            usesAdaptiveClockControl
        ) else {
            throw AUHALSetupFailure(
                stage: .ringBuffer,
                status: kAudio_MemFullError
            )
        }
        renderContext = context
        try installCallbacks(
            context: context,
            inputAudioUnit: inputAudioUnit,
            outputAudioUnit: outputAudioUnit,
            varispeedAudioUnit: varispeedAudioUnit
        )

        try initialize(inputAudioUnit, stage: .inputIO)
        inputInitialized = true
        try initialize(varispeedAudioUnit, stage: .sampleRateConverter)
        varispeedInitialized = true
        try initialize(outputAudioUnit, stage: .outputIO)
        outputInitialized = true
    }

    private func releaseContextForRebuild(
        inputAudioUnit: AudioUnit,
        outputAudioUnit: AudioUnit,
        varispeedAudioUnit: AudioUnit
    ) throws {
        var firstFailureStatus: OSStatus?
        uninitializeForContextRebuild(
            outputAudioUnit,
            role: .outputAUHAL,
            isInitialized: &outputInitialized,
            firstFailureStatus: &firstFailureStatus
        )
        uninitializeForContextRebuild(
            varispeedAudioUnit,
            role: .varispeed,
            isInitialized: &varispeedInitialized,
            firstFailureStatus: &firstFailureStatus
        )
        uninitializeForContextRebuild(
            inputAudioUnit,
            role: .inputAUHAL,
            isInitialized: &inputInitialized,
            firstFailureStatus: &firstFailureStatus
        )
        if let firstFailureStatus {
            throw AUHALSetupFailure(
                stage: .sampleRateConverter,
                status: firstFailureStatus
            )
        }

        let callbackFailures = clearCallbacksForStoppedAudioUnits()
        guard callbackFailures.isEmpty, callbacksAreInvalidated else {
            throw AUHALSetupFailure(
                stage: .sampleRateConverter,
                status: kAudio_ParamError
            )
        }
        guard let renderContext else {
            throw AUHALSetupFailure(
                stage: .sampleRateConverter,
                status: kAudio_ParamError
            )
        }
        asyncSRCLogger.debug(
            "Direct SRC: releasing provisional render context"
        )
        audioUnitOperations.destroyRenderContext(renderContext)
        self.renderContext = nil
        asyncSRCLogger.debug(
            "Direct SRC: provisional render context released"
        )
    }

    private func uninitializeForContextRebuild(
        _ audioUnit: AudioUnit,
        role: AsyncSRCAudioUnitRole,
        isInitialized: inout Bool,
        firstFailureStatus: inout OSStatus?
    ) {
        guard isInitialized else { return }
        asyncSRCLogger.debug(
            "Direct SRC: uninitializing \(role.rawValue, privacy: .public) for context rebuild"
        )
        let status = audioUnitOperations.uninitialize(audioUnit, role)
        if status == noErr || status == kAudioUnitErr_Uninitialized {
            isInitialized = false
            asyncSRCLogger.debug(
                "Direct SRC: \(role.rawValue, privacy: .public) uninitialized for context rebuild"
            )
        } else {
            if firstFailureStatus == nil {
                firstFailureStatus = status
            }
            _ = teardownFailure(
                stage: "uninitializing \(role.rawValue) for context rebuild",
                status: status
            )
        }
    }

    private func configureInputAUHAL(
        _ audioUnit: AudioUnit,
        deviceID: AudioDeviceID,
        channelCount: Int,
        sampleRate: Double,
        maximumFrames: UInt32
    ) throws {
        try setIOEnabled(
            true,
            audioUnit: audioUnit,
            scope: AsyncSRCPlaythroughTopology.inputEnableScope,
            element: AsyncSRCPlaythroughTopology.inputElement,
            stage: .inputIO
        )
        try setIOEnabled(
            false,
            audioUnit: audioUnit,
            scope: AsyncSRCPlaythroughTopology.outputEnableScope,
            element: AsyncSRCPlaythroughTopology.outputElement,
            stage: .outputIO
        )
        try bind(audioUnit, to: deviceID)
        try setMaximumFrames(maximumFrames, on: audioUnit)
        try setFormat(
            Self.makeClientFormat(
                sampleRate: sampleRate,
                channelCount: channelCount
            ),
            on: audioUnit,
            scope: kAudioUnitScope_Output,
            element: AsyncSRCPlaythroughTopology.inputElement
        )
    }

    private func configureOutputAUHAL(
        _ audioUnit: AudioUnit,
        deviceID: AudioDeviceID,
        channelCount: Int,
        sampleRate: Double,
        maximumFrames: UInt32
    ) throws {
        try setIOEnabled(
            false,
            audioUnit: audioUnit,
            scope: AsyncSRCPlaythroughTopology.inputEnableScope,
            element: AsyncSRCPlaythroughTopology.inputElement,
            stage: .inputIO
        )
        try setIOEnabled(
            true,
            audioUnit: audioUnit,
            scope: AsyncSRCPlaythroughTopology.outputEnableScope,
            element: AsyncSRCPlaythroughTopology.outputElement,
            stage: .outputIO
        )
        try bind(audioUnit, to: deviceID)
        try setMaximumFrames(maximumFrames, on: audioUnit)
        try setFormat(
            Self.makeClientFormat(
                sampleRate: sampleRate,
                channelCount: channelCount
            ),
            on: audioUnit,
            scope: kAudioUnitScope_Input,
            element: AsyncSRCPlaythroughTopology.outputElement
        )
    }

    private func configureVarispeed(
        _ audioUnit: AudioUnit,
        channelCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double,
        maximumFrames: UInt32
    ) throws {
        try setMaximumFrames(maximumFrames, on: audioUnit)
        try setFormat(
            Self.makeClientFormat(
                sampleRate: inputSampleRate,
                channelCount: channelCount
            ),
            on: audioUnit,
            scope: kAudioUnitScope_Input,
            element: 0
        )
        try setFormat(
            Self.makeClientFormat(
                sampleRate: outputSampleRate,
                channelCount: channelCount
            ),
            on: audioUnit,
            scope: kAudioUnitScope_Output,
            element: 0
        )
        var renderQuality = UInt32(kRenderQuality_High)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_RenderQuality,
            kAudioUnitScope_Global,
            0,
            &renderQuality,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .sampleRateConverter, status: status)
        }
    }

    private func readConverterLatency(from audioUnit: AudioUnit) throws -> Double {
        var latencySeconds = Float64.zero
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        let latencyStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_Latency,
            kAudioUnitScope_Global,
            0,
            &latencySeconds,
            &latencySize
        )
        guard latencyStatus == noErr,
              latencySeconds.isFinite,
              latencySeconds >= 0 else {
            throw AUHALSetupFailure(
                stage: .sampleRateConverter,
                status: latencyStatus == noErr ? kAudio_ParamError : latencyStatus
            )
        }
        return latencySeconds
    }

    private func installCallbacks(
        context: OpaquePointer,
        inputAudioUnit: AudioUnit,
        outputAudioUnit: AudioUnit,
        varispeedAudioUnit: AudioUnit
    ) throws {
        var inputCallback = AURenderCallbackStruct(
            inputProc: ScreamBarAsyncSRCInputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(context)
        )
        var status = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &inputCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .inputIO, status: status)
        }
        inputCallbackInstalled = true

        var sourceCallback = AURenderCallbackStruct(
            inputProc: ScreamBarAsyncSRCSourceCallback,
            inputProcRefCon: UnsafeMutableRawPointer(context)
        )
        status = AudioUnitSetProperty(
            varispeedAudioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &sourceCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .sampleRateConverter, status: status)
        }
        sourceCallbackInstalled = true

        var outputCallback = AURenderCallbackStruct(
            inputProc: ScreamBarAsyncSRCOutputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(context)
        )
        status = AudioUnitSetProperty(
            outputAudioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            AsyncSRCPlaythroughTopology.outputElement,
            &outputCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .outputIO, status: status)
        }
        outputCallbackInstalled = true
    }

    private var callbacksAreInvalidated: Bool {
        !inputCallbackInstalled
            && !outputCallbackInstalled
            && !sourceCallbackInstalled
    }

    private func clearCallbacksForStoppedAudioUnits() -> [String] {
        var failures: [String] = []

        if !inputStarted, inputCallbackInstalled, let inputAudioUnit {
            failures.append(
                contentsOf: clearCallback(
                    on: inputAudioUnit,
                    role: .input
                )
            )
        }
        if !outputStarted, outputCallbackInstalled, let outputAudioUnit {
            failures.append(
                contentsOf: clearCallback(
                    on: outputAudioUnit,
                    role: .output
                )
            )
        }
        if !outputStarted, sourceCallbackInstalled, let varispeedAudioUnit {
            failures.append(
                contentsOf: clearCallback(
                    on: varispeedAudioUnit,
                    role: .varispeedSource
                )
            )
        }
        return failures
    }

    private func clearCallback(
        on audioUnit: AudioUnit,
        role: AsyncSRCCallbackRole
    ) -> [String] {
        asyncSRCLogger.debug(
            "Direct SRC: removing \(role.rawValue, privacy: .public) callback"
        )
        let status = audioUnitOperations.clearCallback(audioUnit, role)
        guard status == noErr else {
            return [
                teardownFailure(
                    stage: "removing \(role.rawValue) callback",
                    status: status
                ),
            ]
        }
        switch role {
        case .input:
            inputCallbackInstalled = false
        case .output:
            outputCallbackInstalled = false
        case .varispeedSource:
            sourceCallbackInstalled = false
        }
        asyncSRCLogger.debug(
            "Direct SRC: \(role.rawValue, privacy: .public) callback removed"
        )
        return []
    }

    private func initialize(
        _ audioUnit: AudioUnit,
        stage: AUHALConfigurationStage
    ) throws {
        let status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw AUHALSetupFailure(stage: stage, status: status)
        }
    }

    private func setIOEnabled(
        _ enabled: Bool,
        audioUnit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        stage: AUHALConfigurationStage
    ) throws {
        var value: UInt32 = enabled ? 1 : 0
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            scope,
            element,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: stage, status: status)
        }
    }

    private func bind(_ audioUnit: AudioUnit, to deviceID: AudioDeviceID) throws {
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: status)
        }
    }

    private func setMaximumFrames(_ frames: UInt32, on audioUnit: AudioUnit) throws {
        var mutableFrames = frames
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &mutableFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .clientStreamFormat, status: status)
        }
    }

    private func setFormat(
        _ format: AudioStreamBasicDescription,
        on audioUnit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement
    ) throws {
        var mutableFormat = format
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            scope,
            element,
            &mutableFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .clientStreamFormat, status: status)
        }
        var observedFormat = AudioStreamBasicDescription()
        var observedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let readbackStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            scope,
            element,
            &observedFormat,
            &observedSize
        )
        guard readbackStatus == noErr,
              Self.clientFormat(observedFormat, matches: format) else {
            throw AUHALSetupFailure(
                stage: .clientStreamFormat,
                status: readbackStatus == noErr
                    ? kAudioUnitErr_FormatNotSupported
                    : readbackStatus
            )
        }
    }

    private func disposeAudioUnit(
        _ audioUnit: AudioUnit,
        role: AsyncSRCAudioUnitRole
    ) -> String? {
        asyncSRCLogger.debug(
            "Direct SRC: disposing \(role.rawValue, privacy: .public)"
        )
        let status = audioUnitOperations.dispose(audioUnit, role)
        guard status == noErr else {
            return teardownFailure(
                stage: "disposing \(role.rawValue)",
                status: status
            )
        }
        asyncSRCLogger.debug(
            "Direct SRC: \(role.rawValue, privacy: .public) disposed"
        )
        return nil
    }

    private func teardownFailure(stage: String, status: OSStatus) -> String {
        let message = "Direct SRC: \(stage) failed: \(CoreAudioBackendFailure.statusDescription(for: status))"
        asyncSRCLogger.error("\(message, privacy: .public)")
        return message
    }

    static func makeClientFormat(
        sampleRate: Double,
        channelCount: Int
    ) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func clientFormat(
        _ observed: AudioStreamBasicDescription,
        matches expected: AudioStreamBasicDescription
    ) -> Bool {
        let requiredFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        return abs(observed.mSampleRate - expected.mSampleRate) < 0.5
            && observed.mFormatID == kAudioFormatLinearPCM
            && observed.mFormatFlags & requiredFlags == requiredFlags
            && observed.mBytesPerPacket == expected.mBytesPerPacket
            && observed.mFramesPerPacket == expected.mFramesPerPacket
            && observed.mBytesPerFrame == expected.mBytesPerFrame
            && observed.mChannelsPerFrame == expected.mChannelsPerFrame
            && observed.mBitsPerChannel == expected.mBitsPerChannel
    }
}
