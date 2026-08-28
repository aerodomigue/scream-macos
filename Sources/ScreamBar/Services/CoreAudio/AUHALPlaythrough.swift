import AudioToolbox
import CoreAudio
import Foundation
import ScreamBarCoreAudioRT
import os

private let auHALLogger = Logger(subsystem: "com.screambar.app", category: "AUHALPlaythrough")

enum AUHALPlaythroughTopology {
    static let inputElement: AudioUnitElement = 1
    static let outputElement: AudioUnitElement = 0
    static let inputEnableScope: AudioUnitScope = kAudioUnitScope_Input
    static let outputEnableScope: AudioUnitScope = kAudioUnitScope_Output
}

enum AUHALLifecycleState: Equatable {
    case created
    case initialized
    case started
    case stopped
    case uninitialized
    case disposed
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

struct AUHALRetainedConstructionFailure: Error {
    let primaryError: Error
    let playthrough: AUHALPlaythrough
    let cleanupFailures: [String]
}

struct AUHALTeardownOperations {
    let start: (AudioUnit) -> OSStatus
    let stop: (AudioUnit) -> OSStatus
    let clearRenderCallback: (AudioUnit) -> OSStatus
    let uninitialize: (AudioUnit) -> OSStatus
    let dispose: (AudioUnit) -> OSStatus
    let destroyRenderContext: (OpaquePointer) -> Void

    static let live = AUHALTeardownOperations(
        start: AudioOutputUnitStart,
        stop: AudioOutputUnitStop,
        clearRenderCallback: { audioUnit in
            var callback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
            return AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                AUHALPlaythroughTopology.outputElement,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
        },
        uninitialize: AudioUnitUninitialize,
        dispose: AudioComponentInstanceDispose,
        destroyRenderContext: { context in
            ScreamBarRenderContextDestroy(context)
        }
    )
}

final class AUHALPlaythrough {
    private enum ConnectionMode {
        case native
        case renderCallback
    }

    private(set) var lifecycleState: AUHALLifecycleState
    private var audioUnit: AudioUnit?
    private var renderContext: OpaquePointer?
    private let teardownOperations: AUHALTeardownOperations

    var isFullyDisposed: Bool {
        lifecycleState == .disposed && audioUnit == nil && renderContext == nil
    }

    static func make(
        deviceID: AudioDeviceID,
        inputChannelCount: Int,
        inputChannelOffset: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double
    ) throws -> AUHALPlaythrough {
        if inputChannelCount == outputChannelCount {
            do {
                return try makeConfigured(
                    deviceID: deviceID,
                    inputChannelCount: inputChannelCount,
                    inputChannelOffset: inputChannelOffset,
                    outputChannelCount: outputChannelCount,
                    nominalSampleRate: nominalSampleRate,
                    connectionMode: .native
                )
            } catch let failure as AUHALRetainedConstructionFailure {
                throw failure
            } catch let failure as AUHALSetupFailure
                where failure.stage == .playthroughConnection {
                auHALLogger.info(
                    "Native AUHAL playthrough unavailable; using render callback"
                )
            }
        }

        return try makeConfigured(
            deviceID: deviceID,
            inputChannelCount: inputChannelCount,
            inputChannelOffset: inputChannelOffset,
            outputChannelCount: outputChannelCount,
            nominalSampleRate: nominalSampleRate,
            connectionMode: .renderCallback
        )
    }

    private static func makeConfigured(
        deviceID: AudioDeviceID,
        inputChannelCount: Int,
        inputChannelOffset: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double,
        connectionMode: ConnectionMode
    ) throws -> AUHALPlaythrough {
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

        let playthrough = AUHALPlaythrough(
            audioUnit: createdAudioUnit,
            lifecycleState: .created,
            renderContext: nil,
            teardownOperations: .live
        )
        do {
            try playthrough.configure(
                deviceID: deviceID,
                inputChannelCount: inputChannelCount,
                inputChannelOffset: inputChannelOffset,
                outputChannelCount: outputChannelCount,
                nominalSampleRate: nominalSampleRate,
                connectionMode: connectionMode
            )
            let initializationStatus = AudioUnitInitialize(createdAudioUnit)
            guard initializationStatus == noErr else {
                throw AUHALSetupFailure(
                    stage: connectionMode == .native
                        ? .playthroughConnection
                        : .clientStreamFormat,
                    status: initializationStatus
                )
            }
            playthrough.lifecycleState = .initialized
            return playthrough
        } catch {
            let cleanupFailures = playthrough.stopAndDispose()
            if !playthrough.isFullyDisposed {
                throw AUHALRetainedConstructionFailure(
                    primaryError: error,
                    playthrough: playthrough,
                    cleanupFailures: cleanupFailures
                )
            }
            throw error
        }
    }

    init(
        testingAudioUnit: AudioUnit,
        lifecycleState: AUHALLifecycleState,
        renderContext: OpaquePointer? = nil,
        teardownOperations: AUHALTeardownOperations
    ) {
        self.audioUnit = testingAudioUnit
        self.lifecycleState = lifecycleState
        self.renderContext = renderContext
        self.teardownOperations = teardownOperations
    }

    private init(
        audioUnit: AudioUnit,
        lifecycleState: AUHALLifecycleState,
        renderContext: OpaquePointer?,
        teardownOperations: AUHALTeardownOperations
    ) {
        self.audioUnit = audioUnit
        self.lifecycleState = lifecycleState
        self.renderContext = renderContext
        self.teardownOperations = teardownOperations
    }

    func start() throws {
        guard let audioUnit else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        guard lifecycleState == .initialized else {
            if lifecycleState == .started {
                return
            }
            throw AUHALSetupFailure(
                stage: .playthroughConnection,
                status: kAudio_ParamError
            )
        }
        let status = teardownOperations.start(audioUnit)
        guard status == noErr else {
            throw AUHALSetupFailure(stage: .playthroughConnection, status: status)
        }
        lifecycleState = .started
    }

    func stopAndDispose() -> [String] {
        guard let audioUnit else {
            return lifecycleState == .disposed
                ? []
                : ["AUHAL handle unavailable before disposal completed"]
        }

        if lifecycleState == .started {
            auHALLogger.debug("Direct: stopping AUHAL")
            let stopStatus = teardownOperations.stop(audioUnit)
            guard stopStatus == noErr else {
                return [teardownFailure(stage: "stopping AUHAL", status: stopStatus)]
            }
            lifecycleState = .stopped
            auHALLogger.debug("Direct: AUHAL stopped")
        }

        if renderContext != nil {
            auHALLogger.debug("Direct: removing render callback")
            let callbackStatus = teardownOperations.clearRenderCallback(audioUnit)
            if callbackStatus == noErr {
                auHALLogger.debug("Direct: render callback removed")
            } else {
                auHALLogger.debug(
                    "Direct: render callback removal failed: \(CoreAudioBackendFailure.statusDescription(for: callbackStatus), privacy: .public); disposal will invalidate the callback"
                )
            }
        }

        if lifecycleState == .initialized || lifecycleState == .stopped {
            auHALLogger.debug("Direct: uninitializing AUHAL")
            let uninitializeStatus = teardownOperations.uninitialize(audioUnit)
            guard uninitializeStatus == noErr
                    || uninitializeStatus == kAudioUnitErr_Uninitialized else {
                return [teardownFailure(stage: "uninitializing AUHAL", status: uninitializeStatus)]
            }
            lifecycleState = .uninitialized
            auHALLogger.debug("Direct: AUHAL uninitialized")
        }

        if lifecycleState == .created || lifecycleState == .uninitialized {
            auHALLogger.debug("Direct: disposing AUHAL")
            let disposeStatus = teardownOperations.dispose(audioUnit)
            guard disposeStatus == noErr else {
                return [teardownFailure(stage: "disposing AUHAL", status: disposeStatus)]
            }
            lifecycleState = .disposed
            self.audioUnit = nil
            auHALLogger.debug("Direct: AUHAL disposed")
            releaseRenderContext()
        }

        guard isFullyDisposed else {
            return ["Direct: AUHAL teardown stopped at \(lifecycleState)"]
        }
        auHALLogger.debug("Direct: teardown complete")
        return []
    }

    private func releaseRenderContext() {
        guard let renderContext else { return }
        auHALLogger.debug("Direct: releasing render context")
        teardownOperations.destroyRenderContext(renderContext)
        self.renderContext = nil
        auHALLogger.debug("Direct: render context released")
    }

    private func teardownFailure(stage: String, status: OSStatus) -> String {
        let message = "Direct: \(stage) failed: \(CoreAudioBackendFailure.statusDescription(for: status))"
        auHALLogger.error("\(message, privacy: .public)")
        return message
    }

    private func configure(
        deviceID: AudioDeviceID,
        inputChannelCount: Int,
        inputChannelOffset: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double,
        connectionMode: ConnectionMode
    ) throws {
        guard let audioUnit else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        try enableIO(on: audioUnit)
        try bind(audioUnit, to: deviceID)
        try configureInputChannelMap(
            on: audioUnit,
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
            on: audioUnit,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )

        switch connectionMode {
        case .native:
            try configureNativeConnection(on: audioUnit)
        case .renderCallback:
            try configureRenderCallback(
                on: audioUnit,
                inputChannelCount: inputChannelCount,
                outputChannelCount: outputChannelCount
            )
        }
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
        inputChannelCount: Int,
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

        guard let context = ScreamBarRenderContextCreate(
            audioUnit,
            UInt32(inputChannelCount),
            UInt32(outputChannelCount),
            maximumFramesPerSlice
        ) else {
            throw AUHALSetupFailure(
                stage: .clientStreamFormat,
                status: OSStatus(memFullErr)
            )
        }
        renderContext = context
        var callback = AURenderCallbackStruct(
            inputProc: ScreamBarRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(context)
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
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
    }
}
