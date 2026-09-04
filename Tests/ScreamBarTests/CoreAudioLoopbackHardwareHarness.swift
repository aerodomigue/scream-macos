@testable import ScreamBar
import AudioToolbox
import CoreAudio
import Foundation
import ScreamBarLoopbackTestRT

struct CoreAudioLoopbackRawCapture {
    let channels: [[Float]]
    let inputTimestamps: [CoreAudioLoopbackTimestamp]
    let outputTimestamps: [CoreAudioLoopbackTimestamp]
    let renderedFrameCount: UInt64
    let metrics: ScreamBarLoopbackRTMetrics
}

enum CoreAudioLoopbackHarnessError: LocalizedError {
    case componentUnavailable
    case audioUnitCreation(OSStatus)
    case configuration(operation: String, status: OSStatus)
    case contextAllocation
    case cleanup([String])

    var errorDescription: String? {
        switch self {
        case .componentUnavailable:
            return "The HALOutput AudioComponent is unavailable"
        case .audioUnitCreation(let status):
            return "Create loopback AUHAL failed with \(Self.describe(status))"
        case .configuration(let operation, let status):
            return "\(operation) failed with \(Self.describe(status))"
        case .contextAllocation:
            return "Allocate real-time loopback context failed"
        case .cleanup(let failures):
            return "Loopback teardown failed: \(failures.joined(separator: "; "))"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        CoreAudioBackendFailure.statusDescription(for: status)
    }
}

final class CoreAudioLoopbackHardwareHarness {
    private static let float32BitWidth: UInt32 = 32

    private let inputChannelCount: Int
    private let outputChannelCount: Int
    private let captureCapacityFrames: Int
    private let timestampCapacity: Int
    private var inputAudioUnit: AudioUnit?
    private var outputAudioUnit: AudioUnit?
    private var context: OpaquePointer?
    private var inputCallbackInstalled = false
    private var outputCallbackInstalled = false
    private var inputInitialized = false
    private var outputInitialized = false
    private var inputStarted = false
    private var outputStarted = false

    init(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        inputChannelCount: Int,
        outputChannelCount: Int,
        sampleRate: Double,
        outputSignal: [Float],
        captureCapacityFrames: Int,
        maximumCallbackFrames: UInt32,
        timestampCapacity: Int
    ) throws {
        precondition(inputChannelCount > 0)
        precondition(outputChannelCount > 0)
        precondition(captureCapacityFrames > 0)
        precondition(timestampCapacity > 0)
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.captureCapacityFrames = captureCapacityFrames
        self.timestampCapacity = timestampCapacity

        do {
            let inputAudioUnit = try Self.makeAudioUnit()
            self.inputAudioUnit = inputAudioUnit
            let outputAudioUnit = try Self.makeAudioUnit()
            self.outputAudioUnit = outputAudioUnit
            try Self.configureInputAUHAL(
                inputAudioUnit,
                deviceID: inputDeviceID,
                channelCount: inputChannelCount,
                sampleRate: sampleRate,
                maximumCallbackFrames: maximumCallbackFrames
            )
            try Self.configureOutputAUHAL(
                outputAudioUnit,
                deviceID: outputDeviceID,
                channelCount: outputChannelCount,
                sampleRate: sampleRate,
                maximumCallbackFrames: maximumCallbackFrames
            )
            let context = outputSignal.withUnsafeBufferPointer { signalBuffer in
                ScreamBarLoopbackContextCreate(
                    inputAudioUnit,
                    signalBuffer.baseAddress!,
                    UInt64(outputSignal.count),
                    UInt32(inputChannelCount),
                    UInt32(outputChannelCount),
                    UInt64(captureCapacityFrames),
                    maximumCallbackFrames,
                    UInt32(timestampCapacity)
                )
            }
            guard let context else {
                throw CoreAudioLoopbackHarnessError.contextAllocation
            }
            self.context = context
            try installCallbacks(
                context: context,
                inputAudioUnit: inputAudioUnit,
                outputAudioUnit: outputAudioUnit
            )
            try initialize(inputAudioUnit, role: "input AUHAL")
            inputInitialized = true
            try initialize(outputAudioUnit, role: "output AUHAL")
            outputInitialized = true
        } catch {
            let cleanupFailures = cleanupResources()
            if cleanupFailures.isEmpty {
                throw error
            }
            throw CoreAudioLoopbackHarnessError.cleanup(
                [error.localizedDescription] + cleanupFailures
            )
        }
    }

    deinit {
        _ = cleanupResources()
    }

    func startInput() throws {
        guard let inputAudioUnit else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Start input AUHAL",
                status: kAudio_ParamError
            )
        }
        let status = AudioOutputUnitStart(inputAudioUnit)
        guard status == noErr else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Start input AUHAL",
                status: status
            )
        }
        inputStarted = true
    }

    func startOutput() throws {
        guard let outputAudioUnit else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Start output AUHAL",
                status: kAudio_ParamError
            )
        }
        let status = AudioOutputUnitStart(outputAudioUnit)
        guard status == noErr else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Start output AUHAL",
                status: status
            )
        }
        outputStarted = true
    }

    func finish() throws -> CoreAudioLoopbackRawCapture {
        let cleanupFailures = stopDetachUninitializeAndDispose()
        guard cleanupFailures.isEmpty else {
            throw CoreAudioLoopbackHarnessError.cleanup(cleanupFailures)
        }
        guard let context else {
            throw CoreAudioLoopbackHarnessError.contextAllocation
        }
        let capture = copyCapture(from: context)
        ScreamBarLoopbackContextDestroy(context)
        self.context = nil
        return capture
    }

    func cleanupAfterFailure() -> [String] {
        cleanupResources()
    }

    private static func makeAudioUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioLoopbackHarnessError.componentUnavailable
        }
        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            throw CoreAudioLoopbackHarnessError.audioUnitCreation(status)
        }
        return audioUnit
    }

    private static func configureInputAUHAL(
        _ audioUnit: AudioUnit,
        deviceID: AudioDeviceID,
        channelCount: Int,
        sampleRate: Double,
        maximumCallbackFrames: UInt32
    ) throws {
        try setIOEnabled(
            true,
            audioUnit: audioUnit,
            scope: kAudioUnitScope_Input,
            element: 1,
            operation: "Enable input IO"
        )
        try setIOEnabled(
            false,
            audioUnit: audioUnit,
            scope: kAudioUnitScope_Output,
            element: 0,
            operation: "Disable input-unit output IO"
        )
        try bind(audioUnit, to: deviceID)
        try setMaximumFrames(maximumCallbackFrames, on: audioUnit)
        try setFormat(
            makeClientFormat(
                sampleRate: sampleRate,
                channelCount: channelCount
            ),
            on: audioUnit,
            scope: kAudioUnitScope_Output,
            element: 1,
            operation: "Set input client format"
        )
    }

    private static func configureOutputAUHAL(
        _ audioUnit: AudioUnit,
        deviceID: AudioDeviceID,
        channelCount: Int,
        sampleRate: Double,
        maximumCallbackFrames: UInt32
    ) throws {
        try setIOEnabled(
            false,
            audioUnit: audioUnit,
            scope: kAudioUnitScope_Input,
            element: 1,
            operation: "Disable output-unit input IO"
        )
        try setIOEnabled(
            true,
            audioUnit: audioUnit,
            scope: kAudioUnitScope_Output,
            element: 0,
            operation: "Enable output IO"
        )
        try bind(audioUnit, to: deviceID)
        try setMaximumFrames(maximumCallbackFrames, on: audioUnit)
        try setFormat(
            makeClientFormat(
                sampleRate: sampleRate,
                channelCount: channelCount
            ),
            on: audioUnit,
            scope: kAudioUnitScope_Input,
            element: 0,
            operation: "Set output client format"
        )
    }

    private static func setIOEnabled(
        _ enabled: Bool,
        audioUnit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        operation: String
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
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: operation,
                status: status
            )
        }
    }

    private static func bind(
        _ audioUnit: AudioUnit,
        to deviceID: AudioDeviceID
    ) throws {
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
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Bind AUHAL to device \(deviceID)",
                status: status
            )
        }
    }

    private static func setMaximumFrames(
        _ maximumFrames: UInt32,
        on audioUnit: AudioUnit
    ) throws {
        var mutableMaximumFrames = maximumFrames
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &mutableMaximumFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Set maximum callback frames",
                status: status
            )
        }
    }

    private static func setFormat(
        _ format: AudioStreamBasicDescription,
        on audioUnit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        operation: String
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
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: operation,
                status: status
            )
        }
    }

    private static func makeClientFormat(
        sampleRate: Double,
        channelCount: Int
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: Self.float32BitWidth,
            mReserved: 0
        )
    }

    private func installCallbacks(
        context: OpaquePointer,
        inputAudioUnit: AudioUnit,
        outputAudioUnit: AudioUnit
    ) throws {
        var inputCallback = AURenderCallbackStruct(
            inputProc: ScreamBarLoopbackInputCallback,
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
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Install input callback",
                status: status
            )
        }
        inputCallbackInstalled = true

        var outputCallback = AURenderCallbackStruct(
            inputProc: ScreamBarLoopbackOutputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(context)
        )
        status = AudioUnitSetProperty(
            outputAudioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &outputCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Install output callback",
                status: status
            )
        }
        outputCallbackInstalled = true
    }

    private func initialize(_ audioUnit: AudioUnit, role: String) throws {
        let status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw CoreAudioLoopbackHarnessError.configuration(
                operation: "Initialize \(role)",
                status: status
            )
        }
    }

    private func stopDetachUninitializeAndDispose() -> [String] {
        var failures: [String] = []
        stopIfNeeded(
            &outputStarted,
            audioUnit: outputAudioUnit,
            role: "output AUHAL",
            failures: &failures
        )
        stopIfNeeded(
            &inputStarted,
            audioUnit: inputAudioUnit,
            role: "input AUHAL",
            failures: &failures
        )
        clearCallbacks(failures: &failures)
        uninitializeIfNeeded(
            &outputInitialized,
            audioUnit: outputAudioUnit,
            role: "output AUHAL",
            failures: &failures
        )
        uninitializeIfNeeded(
            &inputInitialized,
            audioUnit: inputAudioUnit,
            role: "input AUHAL",
            failures: &failures
        )
        dispose(&outputAudioUnit, role: "output AUHAL", failures: &failures)
        dispose(&inputAudioUnit, role: "input AUHAL", failures: &failures)
        return failures
    }

    private func cleanupResources() -> [String] {
        let failures = stopDetachUninitializeAndDispose()
        if inputAudioUnit == nil, outputAudioUnit == nil, let context {
            ScreamBarLoopbackContextDestroy(context)
            self.context = nil
        }
        return failures
    }

    private func stopIfNeeded(
        _ started: inout Bool,
        audioUnit: AudioUnit?,
        role: String,
        failures: inout [String]
    ) {
        guard started, let audioUnit else { return }
        let status = AudioOutputUnitStop(audioUnit)
        if status == noErr {
            started = false
        } else {
            failures.append(
                "Stop \(role): \(CoreAudioBackendFailure.statusDescription(for: status))"
            )
        }
    }

    private func clearCallbacks(failures: inout [String]) {
        var emptyCallback = AURenderCallbackStruct(
            inputProc: nil,
            inputProcRefCon: nil
        )
        if outputCallbackInstalled, let outputAudioUnit {
            let status = AudioUnitSetProperty(
                outputAudioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &emptyCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            if status == noErr {
                outputCallbackInstalled = false
            } else {
                failures.append(
                    "Clear output callback: \(CoreAudioBackendFailure.statusDescription(for: status))"
                )
            }
        }
        if inputCallbackInstalled, let inputAudioUnit {
            let status = AudioUnitSetProperty(
                inputAudioUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &emptyCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            if status == noErr {
                inputCallbackInstalled = false
            } else {
                failures.append(
                    "Clear input callback: \(CoreAudioBackendFailure.statusDescription(for: status))"
                )
            }
        }
    }

    private func uninitializeIfNeeded(
        _ initialized: inout Bool,
        audioUnit: AudioUnit?,
        role: String,
        failures: inout [String]
    ) {
        guard initialized, let audioUnit else { return }
        let status = AudioUnitUninitialize(audioUnit)
        if status == noErr {
            initialized = false
        } else {
            failures.append(
                "Uninitialize \(role): \(CoreAudioBackendFailure.statusDescription(for: status))"
            )
        }
    }

    private func dispose(
        _ audioUnit: inout AudioUnit?,
        role: String,
        failures: inout [String]
    ) {
        guard let activeAudioUnit = audioUnit else { return }
        let status = AudioComponentInstanceDispose(activeAudioUnit)
        if status == noErr {
            audioUnit = nil
        } else {
            failures.append(
                "Dispose \(role): \(CoreAudioBackendFailure.statusDescription(for: status))"
            )
        }
    }

    private func copyCapture(
        from context: OpaquePointer
    ) -> CoreAudioLoopbackRawCapture {
        let capturedFrameCount = Int(
            ScreamBarLoopbackCapturedFrameCount(context)
        )
        var channels: [[Float]] = []
        channels.reserveCapacity(inputChannelCount)
        for channelIndex in 0..<inputChannelCount {
            var samples = [Float](
                repeating: 0,
                count: capturedFrameCount
            )
            samples.withUnsafeMutableBufferPointer { buffer in
                _ = ScreamBarLoopbackCopyCapturedChannel(
                    context,
                    UInt32(channelIndex),
                    buffer.baseAddress!,
                    UInt64(buffer.count)
                )
            }
            channels.append(samples)
        }
        return CoreAudioLoopbackRawCapture(
            channels: channels,
            inputTimestamps: copyTimestamps(
                from: context,
                input: true
            ),
            outputTimestamps: copyTimestamps(
                from: context,
                input: false
            ),
            renderedFrameCount: ScreamBarLoopbackOutputFrameCount(context),
            metrics: copyMetrics(from: context)
        )
    }

    private func copyTimestamps(
        from context: OpaquePointer,
        input: Bool
    ) -> [CoreAudioLoopbackTimestamp] {
        var records = [ScreamBarLoopbackTimestampRecord](
            repeating: ScreamBarLoopbackTimestampRecord(),
            count: timestampCapacity
        )
        let count = records.withUnsafeMutableBufferPointer { buffer in
            if input {
                return ScreamBarLoopbackCopyInputTimestamps(
                    context,
                    buffer.baseAddress!,
                    UInt32(buffer.count)
                )
            }
            return ScreamBarLoopbackCopyOutputTimestamps(
                context,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        return records.prefix(Int(count)).map { record in
            CoreAudioLoopbackTimestamp(
                frameOffset: record.frame_offset,
                frameCount: record.frame_count,
                hostTime: record.host_time,
                sampleTime: record.sample_time,
                flags: record.timestamp_flags
            )
        }
    }

    private func copyMetrics(
        from context: OpaquePointer
    ) -> ScreamBarLoopbackRTMetrics {
        var metrics = ScreamBarLoopbackRTMetrics()
        ScreamBarLoopbackCopyMetrics(context, &metrics)
        return metrics
    }
}
