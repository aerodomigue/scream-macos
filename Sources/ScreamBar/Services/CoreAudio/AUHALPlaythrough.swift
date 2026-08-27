import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import os

private let auHALLogger = Logger(subsystem: "com.screambar.app", category: "AUHALPlaythrough")

enum AUHALPlaythroughTopology {
    static let inputElement: AudioUnitElement = 1
    static let outputElement: AudioUnitElement = 0
    static let inputEnableScope: AudioUnitScope = kAudioUnitScope_Input
    static let outputEnableScope: AudioUnitScope = kAudioUnitScope_Output
}

struct AUHALSetupFailure: LocalizedError {
    let stage: AUHALConfigurationStage
    let status: OSStatus

    var errorDescription: String? {
        "AUHAL \(stage.rawValue) failed with OSStatus \(status)"
    }
}

struct AUHALCreationFailure: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "AUHAL creation failed with OSStatus \(status)"
    }
}

final class AUHALPlaythrough {
    private enum ConnectionMode {
        case native
        case renderCallback
    }

    private var audioUnit: AudioUnit?
    private var renderContext: AUHALRenderContext?
    private var isStarted = false

    static func make(
        deviceID: AudioDeviceID,
        inputChannelCount: Int,
        inputChannelOffset: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double
    ) throws -> AUHALPlaythrough {
        if inputChannelCount == outputChannelCount {
            do {
                return try AUHALPlaythrough(
                    deviceID: deviceID,
                    inputChannelCount: inputChannelCount,
                    inputChannelOffset: inputChannelOffset,
                    outputChannelCount: outputChannelCount,
                    nominalSampleRate: nominalSampleRate,
                    preferredConnectionMode: .native
                )
            } catch let failure as AUHALSetupFailure where failure.stage == .playthroughConnection {
                auHALLogger.info("Native AUHAL playthrough unavailable; using render callback")
            }
        }

        return try AUHALPlaythrough(
            deviceID: deviceID,
            inputChannelCount: inputChannelCount,
            inputChannelOffset: inputChannelOffset,
            outputChannelCount: outputChannelCount,
            nominalSampleRate: nominalSampleRate,
            preferredConnectionMode: .renderCallback
        )
    }

    private init(
        deviceID: AudioDeviceID,
        inputChannelCount: Int,
        inputChannelOffset: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double,
        preferredConnectionMode: ConnectionMode
    ) throws {
        guard inputChannelCount > 0, outputChannelCount > 0 else {
            throw AUHALSetupFailure(stage: .channelMapping, status: kAudio_ParamError)
        }

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw AUHALCreationFailure(status: kAudio_ParamError)
        }

        var createdAudioUnit: AudioUnit?
        let creationStatus = AudioComponentInstanceNew(component, &createdAudioUnit)
        guard creationStatus == noErr, let createdAudioUnit else {
            throw AUHALCreationFailure(status: creationStatus)
        }
        audioUnit = createdAudioUnit

        do {
            try enableIO(on: createdAudioUnit)
            try bind(createdAudioUnit, to: deviceID)
            try configureInputChannelMap(
                on: createdAudioUnit,
                inputChannelCount: inputChannelCount,
                inputChannelOffset: inputChannelOffset
            )

            let inputFormat = Self.makeClientFormat(
                sampleRate: nominalSampleRate,
                channelCount: inputChannelCount
            )
            let outputFormat = Self.makeClientFormat(
                sampleRate: nominalSampleRate,
                channelCount: outputChannelCount
            )
            try setClientFormats(
                on: createdAudioUnit,
                inputFormat: inputFormat,
                outputFormat: outputFormat
            )

            switch preferredConnectionMode {
            case .native:
                try configureNativeConnection(on: createdAudioUnit)
            case .renderCallback:
                try configureRenderCallback(
                    on: createdAudioUnit,
                    inputFormat: inputFormat,
                    outputChannelCount: outputChannelCount
                )
            }

            let initializationStatus = AudioUnitInitialize(createdAudioUnit)
            guard initializationStatus == noErr else {
                throw AUHALSetupFailure(
                    stage: preferredConnectionMode == .native ? .playthroughConnection : .clientStreamFormat,
                    status: initializationStatus
                )
            }
        } catch {
            _ = disposeResources()
            throw error
        }
    }

    func start() throws {
        guard let audioUnit else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        guard !isStarted else { return }
        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .playthroughConnection, status: status)
        }
        isStarted = true
    }

    func stopAndDispose() -> [String] {
        disposeResources()
    }

    private func enableIO(on audioUnit: AudioUnit) throws {
        var enabled: UInt32 = 1
        var status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            AUHALPlaythroughTopology.inputEnableScope,
            AUHALPlaythroughTopology.inputElement,
            &enabled,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .inputIO, status: status)
        }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            AUHALPlaythroughTopology.outputEnableScope,
            AUHALPlaythroughTopology.outputElement,
            &enabled,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .outputIO, status: status)
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

    private func configureInputChannelMap(
        on audioUnit: AudioUnit,
        inputChannelCount: Int,
        inputChannelOffset: Int
    ) throws {
        guard inputChannelOffset > 0 else { return }
        var channelMap = (0..<inputChannelCount).map {
            Int32(inputChannelOffset + $0)
        }
        let status = channelMap.withUnsafeMutableBytes { channelMapBytes in
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                1,
                channelMapBytes.baseAddress,
                UInt32(channelMapBytes.count)
            )
        }
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .channelMapping, status: status)
        }
    }

    private func setClientFormats(
        on audioUnit: AudioUnit,
        inputFormat: AudioStreamBasicDescription,
        outputFormat: AudioStreamBasicDescription
    ) throws {
        var mutableInputFormat = inputFormat
        var status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &mutableInputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .clientStreamFormat, status: status)
        }

        var mutableOutputFormat = outputFormat
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &mutableOutputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .clientStreamFormat, status: status)
        }

        try verifyClientFormat(
            on: audioUnit,
            scope: kAudioUnitScope_Output,
            element: 1,
            expectedFormat: inputFormat
        )
        try verifyClientFormat(
            on: audioUnit,
            scope: kAudioUnitScope_Input,
            element: 0,
            expectedFormat: outputFormat
        )
    }

    private func verifyClientFormat(
        on audioUnit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        expectedFormat: AudioStreamBasicDescription
    ) throws {
        var actualFormat = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            scope,
            element,
            &actualFormat,
            &dataSize
        )
        guard status == noErr,
              NominalSampleRateNegotiator.ratesMatch(
                  actualFormat.mSampleRate,
                  expectedFormat.mSampleRate
              ),
              actualFormat.mFormatID == expectedFormat.mFormatID,
              actualFormat.mChannelsPerFrame == expectedFormat.mChannelsPerFrame,
              actualFormat.mBitsPerChannel == expectedFormat.mBitsPerChannel,
              actualFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              actualFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 else {
            throw AUHALSetupFailure(
                stage: .clientStreamFormat,
                status: status == noErr ? kAudio_ParamError : status
            )
        }
    }

    private func configureNativeConnection(on audioUnit: AudioUnit) throws {
        var connection = AudioUnitConnection(
            sourceAudioUnit: audioUnit,
            sourceOutputNumber: 1,
            destInputNumber: 0
        )
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MakeConnection,
            kAudioUnitScope_Input,
            0,
            &connection,
            UInt32(MemoryLayout<AudioUnitConnection>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .playthroughConnection, status: status)
        }
    }

    private func configureRenderCallback(
        on audioUnit: AudioUnit,
        inputFormat: AudioStreamBasicDescription,
        outputChannelCount: Int
    ) throws {
        var maximumFramesPerSlice: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let frameStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFramesPerSlice,
            &propertySize
        )
        guard frameStatus == noErr, maximumFramesPerSlice > 0 else {
            throw AUHALSetupFailure(
                stage: .clientStreamFormat,
                status: frameStatus == noErr ? kAudio_ParamError : frameStatus
            )
        }

        var mutableInputFormat = inputFormat
        guard let avInputFormat = AVAudioFormat(streamDescription: &mutableInputFormat),
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: avInputFormat,
                  frameCapacity: maximumFramesPerSlice
              ) else {
            throw AUHALSetupFailure(stage: .clientStreamFormat, status: kAudio_ParamError)
        }

        let context = AUHALRenderContext(
            audioUnit: audioUnit,
            inputBuffer: inputBuffer,
            outputChannelCount: outputChannelCount
        )
        renderContext = context
        var callback = AURenderCallbackStruct(
            inputProc: auHALPlaythroughRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .playthroughConnection, status: status)
        }
    }

    private func disposeResources() -> [String] {
        guard let audioUnit else { return [] }
        var failures: [String] = []

        if isStarted {
            let stopStatus = AudioOutputUnitStop(audioUnit)
            if stopStatus != noErr {
                failures.append("stop AUHAL (\(stopStatus))")
            }
            isStarted = false
        }

        let uninitializeStatus = AudioUnitUninitialize(audioUnit)
        if uninitializeStatus != noErr && uninitializeStatus != kAudioUnitErr_Uninitialized {
            failures.append("uninitialize AUHAL (\(uninitializeStatus))")
        }

        let disposeStatus = AudioComponentInstanceDispose(audioUnit)
        if disposeStatus != noErr {
            failures.append("dispose AUHAL (\(disposeStatus))")
        }

        self.audioUnit = nil
        renderContext = nil
        return failures
    }

    static func makeClientFormat(
        sampleRate: Double,
        channelCount: Int
    ) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
    }
}

private final class AUHALRenderContext {
    private let audioUnit: AudioUnit
    private let inputBuffer: AVAudioPCMBuffer
    private let outputChannelCount: Int

    init(
        audioUnit: AudioUnit,
        inputBuffer: AVAudioPCMBuffer,
        outputChannelCount: Int
    ) {
        self.audioUnit = audioUnit
        self.inputBuffer = inputBuffer
        self.outputChannelCount = outputChannelCount
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        clear(outputBuffers: outputBuffers)

        guard frameCount <= inputBuffer.frameCapacity else {
            actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return kAudio_ParamError
        }

        inputBuffer.frameLength = frameCount
        let renderStatus = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            1,
            frameCount,
            inputBuffer.mutableAudioBufferList
        )
        guard renderStatus == noErr, let inputChannels = inputBuffer.floatChannelData else {
            actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return renderStatus
        }

        let inputChannelCount = Int(inputBuffer.format.channelCount)
        let byteCount = Int(frameCount) * MemoryLayout<Float32>.size
        for outputIndex in 0..<min(outputBuffers.count, outputChannelCount) {
            guard let sourceIndex = sourceChannelIndex(
                outputIndex: outputIndex,
                inputChannelCount: inputChannelCount
            ),
            let destination = outputBuffers[outputIndex].mData else {
                continue
            }
            memcpy(destination, inputChannels[sourceIndex], byteCount)
            outputBuffers[outputIndex].mDataByteSize = UInt32(byteCount)
        }
        return noErr
    }

    private func sourceChannelIndex(
        outputIndex: Int,
        inputChannelCount: Int
    ) -> Int? {
        if inputChannelCount == 1 {
            return outputIndex < 2 ? 0 : nil
        }
        return outputIndex < inputChannelCount ? outputIndex : nil
    }

    private func clear(outputBuffers: UnsafeMutableAudioBufferListPointer) {
        for index in outputBuffers.indices {
            guard let destination = outputBuffers[index].mData else { continue }
            memset(destination, 0, Int(outputBuffers[index].mDataByteSize))
        }
    }
}

private let auHALPlaythroughRenderCallback: AURenderCallback = {
    referenceContext,
    actionFlags,
    timestamp,
    _,
    frameCount,
    outputData in
    guard let outputData else {
        return kAudio_ParamError
    }
    let context = Unmanaged<AUHALRenderContext>
        .fromOpaque(referenceContext)
        .takeUnretainedValue()
    return context.render(
        actionFlags: actionFlags,
        timestamp: timestamp,
        frameCount: frameCount,
        outputData: outputData
    )
}
