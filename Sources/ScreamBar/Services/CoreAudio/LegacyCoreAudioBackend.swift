import CoreAudio
import Foundation
import os

private let legacyCoreAudioLogger = Logger(
    subsystem: "com.screambar.app",
    category: "LegacyCoreAudioBackend"
)

enum LegacyRouteFailure: Error {
    case bufferFrameSizeConfiguration(BufferFrameSizeConfigurationContext)
    case aggregateUnsupported(OSStatus)
    case aggregateCreation(OSStatus)
    case aggregateVerification(String)
    case auHALCreation(OSStatus)
    case auHAL(AUHALSetupFailure)
}

@MainActor
final class LegacyCoreAudioBackend: CoreAudioBackend {
    var onHardwareChanged: (() -> Void)?

    private struct ListenerRegistration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    }

    private struct RouteResources {
        let aggregateDeviceID: AudioDeviceID?
        let playthrough: AUHALPlaythrough
        let bufferFrameSizeRestores: [BufferFrameSizeRestore]
    }

    private struct BufferFrameSizeRestore {
        let deviceUID: AudioDeviceUID
        let frameCount: UInt32
        let appliedFrameCount: UInt32
    }

    private static let aggregateName = "ScreamBar Direct Routing"
    private static let aggregateUIDPrefix = "com.screambar.direct-routing."
    private static let defaultDeviceResolutionAttempts = 3

    private let listenerQueue = DispatchQueue(
        label: "com.screambar.coreaudio-listeners",
        qos: .userInitiated
    )
    private var listeners: [ListenerRegistration] = []
    private var routes: [UUID: RouteResources] = [:]

    func startMonitoring() throws {
        try rebuildListeners()
    }

    func stopMonitoring() {
        for registration in listeners {
            var address = registration.address
            let status = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                listenerQueue,
                registration.block
            )
            if status != noErr {
                legacyCoreAudioLogger.error(
                    "Failed to remove CoreAudio listener: \(status)"
                )
            }
        }
        listeners.removeAll()
    }

    func rebuildListeners() throws {
        stopMonitoring()

        let systemAddresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
        for address in systemAddresses {
            try addListener(objectID: AudioObjectID(kAudioObjectSystemObject), address: address)
        }

        for deviceID in try allDeviceIDs() {
            do {
                if try isOwnedAggregate(deviceID: deviceID) {
                    continue
                }
            } catch {
                legacyCoreAudioLogger.warning(
                    "Skipping listeners for unreadable CoreAudio device \(deviceID): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            let deviceAddresses = [
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
            ]
            for address in deviceAddresses {
                if CoreAudioPropertyReader.hasProperty(
                    objectID: deviceID,
                    address: address
                ) {
                    try addListener(objectID: deviceID, address: address)
                }
            }
        }
    }

    func makeSnapshot(revision: UInt64) throws -> AudioHardwareSnapshot {
        let devices = try allDeviceIDs().compactMap { deviceID -> AudioDeviceDescriptor? in
            do {
                if try isOwnedAggregate(deviceID: deviceID) {
                    return nil
                }
                return try descriptor(for: deviceID)
            } catch {
                legacyCoreAudioLogger.warning(
                    "Ignoring unreadable CoreAudio device \(deviceID): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        return AudioHardwareSnapshot(
            revision: revision,
            devices: devices.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            defaultInputUID: try defaultDeviceUID(
                selector: kAudioHardwarePropertyDefaultInputDevice
            ),
            defaultOutputUID: try defaultDeviceUID(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
        )
    }

    func currentNominalSampleRate(for uid: AudioDeviceUID) throws -> Double {
        let deviceID = try deviceID(for: uid)
        return try CoreAudioPropertyReader.readFloat64(
            objectID: deviceID,
            address: nominalSampleRateAddress
        )
    }

    func setNominalSampleRate(_ rate: Double, for uid: AudioDeviceUID) throws {
        let deviceID = try deviceID(for: uid)
        try CoreAudioPropertyReader.writeFloat64(
            rate,
            objectID: deviceID,
            address: nominalSampleRateAddress
        )
    }

    func isAlive(uid: AudioDeviceUID) throws -> Bool {
        let deviceID = try deviceID(for: uid)
        return try CoreAudioPropertyReader.readUInt32(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ) != 0
    }

    func prepareRoute(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?
    ) throws -> UUID {
        let inputDeviceID = try deviceID(for: input.id)
        let outputDeviceID = try deviceID(for: output.id)
        var aggregateDeviceID: AudioDeviceID?
        var bufferFrameSizeRestores: [BufferFrameSizeRestore] = []

        do {
            if let requestedBufferFrameSize {
                if let outputRestore = try configureBufferFrameSize(
                    requestedBufferFrameSize,
                    deviceUID: output.id,
                    deviceID: outputDeviceID
                ) {
                    bufferFrameSizeRestores.append(outputRestore)
                }
                if input.id != output.id,
                   let inputRestore = try configureBufferFrameSize(
                       requestedBufferFrameSize,
                       deviceUID: input.id,
                       deviceID: inputDeviceID
                   ) {
                    bufferFrameSizeRestores.append(inputRestore)
                }
            }

            let routeDeviceID: AudioDeviceID
            let inputChannelOffset: Int
            if input.id == output.id {
                routeDeviceID = inputDeviceID
                inputChannelOffset = 0
            } else {
                let createdAggregateID = try createAggregateDevice(
                    input: input,
                    output: output,
                    nominalSampleRate: nominalSampleRate,
                    requestedBufferFrameSize: requestedBufferFrameSize
                )
                aggregateDeviceID = createdAggregateID
                routeDeviceID = createdAggregateID
                inputChannelOffset = output.inputChannelCount
            }

            let playthrough: AUHALPlaythrough
            do {
                playthrough = try AUHALPlaythrough.make(
                    deviceID: routeDeviceID,
                    inputChannelCount: input.inputChannelCount,
                    inputChannelOffset: inputChannelOffset,
                    outputChannelCount: output.outputChannelCount,
                    nominalSampleRate: nominalSampleRate
                )
            } catch let failure as AUHALCreationFailure {
                throw LegacyRouteFailure.auHALCreation(failure.status)
            } catch let failure as AUHALSetupFailure {
                throw LegacyRouteFailure.auHAL(failure)
            }

            let sessionID = UUID()
            routes[sessionID] = RouteResources(
                aggregateDeviceID: aggregateDeviceID,
                playthrough: playthrough,
                bufferFrameSizeRestores: bufferFrameSizeRestores
            )
            return sessionID
        } catch {
            if let aggregateDeviceID {
                let cleanupStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                if cleanupStatus != noErr {
                    legacyCoreAudioLogger.error(
                        "Failed to destroy aggregate after prepare error: \(cleanupStatus)"
                    )
                }
            }
            restoreBufferFrameSizes(bufferFrameSizeRestores).forEach {
                legacyCoreAudioLogger.error("\($0, privacy: .public)")
            }
            throw error
        }
    }

    func startRoute(sessionID: UUID) throws {
        guard let resources = routes[sessionID] else {
            throw AUHALSetupFailure(stage: .deviceBinding, status: kAudio_ParamError)
        }
        try resources.playthrough.start()
    }

    func stopAndDestroyRoute(sessionID: UUID) -> [String] {
        guard let resources = routes.removeValue(forKey: sessionID) else { return [] }
        var failures = resources.playthrough.stopAndDispose()
        if let aggregateDeviceID = resources.aggregateDeviceID {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr {
                failures.append("destroy aggregate (\(status))")
            }
        }
        failures.append(
            contentsOf: restoreBufferFrameSizes(resources.bufferFrameSizeRestores)
        )
        return failures
    }

    func shutdown() -> [String] {
        var failures: [String] = []
        for sessionID in Array(routes.keys) {
            failures.append(contentsOf: stopAndDestroyRoute(sessionID: sessionID))
        }
        stopMonitoring()
        return failures
    }

    private var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var bufferFrameSizeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var bufferFrameSizeRangeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws {
        let block: (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.onHardwareChanged?()
            }
        }
        var mutableAddress = address
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &mutableAddress,
            listenerQueue,
            block
        )
        guard status == noErr else {
            throw CoreAudioBackendFailure(operation: "Add CoreAudio listener", status: status)
        }
        listeners.append(
            ListenerRegistration(objectID: objectID, address: address, block: block)
        )
    }

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        try CoreAudioPropertyReader.readDeviceIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    private func deviceID(for uid: AudioDeviceUID) throws -> AudioDeviceID {
        for deviceID in try allDeviceIDs() {
            do {
                let candidateUID = try CoreAudioPropertyReader.readString(
                    objectID: deviceID,
                    address: AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                )
                if candidateUID == uid.rawValue {
                    return deviceID
                }
            } catch {
                legacyCoreAudioLogger.warning(
                    "Ignoring unreadable CoreAudio device \(deviceID) while resolving UID: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        throw CoreAudioBackendFailure(
            operation: "Resolve device UID \(uid.rawValue)",
            status: kAudioHardwareBadDeviceError
        )
    }

    private func isOwnedAggregate(deviceID: AudioDeviceID) throws -> Bool {
        let uid = try CoreAudioPropertyReader.readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        return uid.hasPrefix(Self.aggregateUIDPrefix)
    }

    private func descriptor(for deviceID: AudioDeviceID) throws -> AudioDeviceDescriptor {
        let uid = try CoreAudioPropertyReader.readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let name = try CoreAudioPropertyReader.readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let ranges = try CoreAudioPropertyReader.readValueRanges(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let bufferMetadata = readBufferFrameMetadata(deviceID: deviceID)
        return AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: name,
            inputChannelCount: try CoreAudioPropertyReader.readChannelCount(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeInput
            ),
            outputChannelCount: try CoreAudioPropertyReader.readChannelCount(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            ),
            isAlive: try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ) != 0,
            currentNominalSampleRate: try CoreAudioPropertyReader.readFloat64(
                objectID: deviceID,
                address: nominalSampleRateAddress
            ),
            supportedNominalSampleRates: ranges.map {
                NominalSampleRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum)
            },
            currentBufferFrameSize: bufferMetadata.current,
            supportedBufferFrameSizeRange: bufferMetadata.range
        )
    }

    private func readBufferFrameMetadata(
        deviceID: AudioDeviceID
    ) -> (current: UInt32?, range: AudioBufferFrameSizeRange?) {
        let currentAddress = bufferFrameSizeAddress
        let rangeAddress = bufferFrameSizeRangeAddress
        guard CoreAudioPropertyReader.hasProperty(
            objectID: deviceID,
            address: currentAddress
        ), CoreAudioPropertyReader.hasProperty(
            objectID: deviceID,
            address: rangeAddress
        ) else {
            return (nil, nil)
        }

        do {
            let current = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: currentAddress
            )
            let valueRange = try CoreAudioPropertyReader.readValueRange(
                objectID: deviceID,
                address: rangeAddress
            )
            guard valueRange.mMinimum.isFinite,
                  valueRange.mMaximum.isFinite,
                  valueRange.mMinimum > 0,
                  valueRange.mMaximum >= valueRange.mMinimum,
                  valueRange.mMaximum <= Double(UInt32.max) else {
                legacyCoreAudioLogger.warning(
                    "Ignoring invalid buffer frame range for CoreAudio device \(deviceID)"
                )
                return (current, nil)
            }
            return (
                current,
                AudioBufferFrameSizeRange(
                    minimum: UInt32(valueRange.mMinimum.rounded(.up)),
                    maximum: UInt32(valueRange.mMaximum.rounded(.down))
                )
            )
        } catch {
            legacyCoreAudioLogger.warning(
                "Failed to read buffer frame metadata for CoreAudio device \(deviceID): \(error.localizedDescription, privacy: .public)"
            )
            return (nil, nil)
        }
    }

    private func defaultDeviceUID(
        selector: AudioObjectPropertySelector
    ) throws -> AudioDeviceUID? {
        var lastFailure: Error?
        for _ in 0..<Self.defaultDeviceResolutionAttempts {
            let deviceID = try CoreAudioPropertyReader.readAudioDeviceID(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
            guard deviceID != kAudioObjectUnknown else { return nil }
            do {
                let uid = try CoreAudioPropertyReader.readString(
                    objectID: deviceID,
                    address: AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                )
                return AudioDeviceUID(rawValue: uid)
            } catch let failure as CoreAudioBackendFailure
                where failure.status == kAudioHardwareBadObjectError {
                lastFailure = failure
            }
        }
        if let lastFailure {
            throw lastFailure
        }
        throw CoreAudioBackendFailure(
            operation: "Resolve default CoreAudio device",
            status: kAudioHardwareBadDeviceError
        )
    }

    private func createAggregateDevice(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?
    ) throws -> AudioDeviceID {
        let description = Self.makeAggregateDescription(input: input, output: output)

        var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let creationStatus = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateDeviceID
        )
        guard creationStatus == noErr else {
            if creationStatus == kAudioHardwareUnsupportedOperationError {
                throw LegacyRouteFailure.aggregateUnsupported(creationStatus)
            }
            throw LegacyRouteFailure.aggregateCreation(creationStatus)
        }

        do {
            try configureAndVerifyAggregate(
                aggregateDeviceID: aggregateDeviceID,
                expectedOutputUID: output.id,
                nominalSampleRate: nominalSampleRate,
                requestedBufferFrameSize: requestedBufferFrameSize
            )
            return aggregateDeviceID
        } catch {
            let cleanupStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if cleanupStatus != noErr {
                legacyCoreAudioLogger.error(
                    "Failed to destroy invalid aggregate: \(cleanupStatus)"
                )
            }
            throw error
        }
    }

    static func makeAggregateDescription(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) -> [String: Any] {
        let aggregateUID = "\(aggregateUIDPrefix)\(UUID().uuidString)"
        let outputSubdevice: [String: Any] = [
            kAudioSubDeviceUIDKey: output.id.rawValue,
            kAudioSubDeviceDriftCompensationKey: 0,
        ]
        let inputSubdevice: [String: Any] = [
            kAudioSubDeviceUIDKey: input.id.rawValue,
            kAudioSubDeviceDriftCompensationKey: 1,
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: output.id.rawValue,
            kAudioAggregateDeviceSubDeviceListKey: [outputSubdevice, inputSubdevice],
        ]
        return description
    }

    private func configureAndVerifyAggregate(
        aggregateDeviceID: AudioDeviceID,
        expectedOutputUID: AudioDeviceUID,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?
    ) throws {
        let activeSubdevices = try CoreAudioPropertyReader.readAudioObjectIDs(
            objectID: aggregateDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        guard activeSubdevices.count >= 2 else {
            throw LegacyRouteFailure.aggregateVerification("Aggregate subdevices are incomplete")
        }

        try CoreAudioPropertyReader.writeFloat64(
            nominalSampleRate,
            objectID: aggregateDeviceID,
            address: nominalSampleRateAddress
        )
        let observedRate = try CoreAudioPropertyReader.readFloat64(
            objectID: aggregateDeviceID,
            address: nominalSampleRateAddress
        )
        guard NominalSampleRateNegotiator.ratesMatch(observedRate, nominalSampleRate) else {
            throw LegacyRouteFailure.aggregateVerification("Aggregate nominal sample rate mismatch")
        }

        let masterUID = try CoreAudioPropertyReader.readString(
            objectID: aggregateDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyMainSubDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        guard masterUID == expectedOutputUID.rawValue else {
            throw LegacyRouteFailure.aggregateVerification("Output is not the aggregate master")
        }

        if let requestedBufferFrameSize {
            try configureAggregateBufferFrameSize(
                requestedBufferFrameSize,
                aggregateDeviceID: aggregateDeviceID
            )
        }
    }

    private func configureBufferFrameSize(
        _ requestedFrameCount: UInt32,
        deviceUID: AudioDeviceUID,
        deviceID: AudioDeviceID
    ) throws -> BufferFrameSizeRestore? {
        let originalFrameCount: UInt32
        do {
            originalFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
        } catch {
            throw LegacyRouteFailure.bufferFrameSizeConfiguration(
                BufferFrameSizeConfigurationContext(
                    deviceUID: deviceUID,
                    requestedFrameCount: requestedFrameCount,
                    observedFrameCount: nil,
                    operation: "read original buffer frame size"
                )
            )
        }
        guard originalFrameCount != requestedFrameCount else { return nil }

        do {
            try CoreAudioPropertyReader.writeUInt32(
                requestedFrameCount,
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            guard observedFrameCount == requestedFrameCount else {
                let restorationSuffix = immediateBufferRestoreSuffix(
                    originalFrameCount,
                    deviceUID: deviceUID,
                    deviceID: deviceID
                )
                throw LegacyRouteFailure.bufferFrameSizeConfiguration(
                    BufferFrameSizeConfigurationContext(
                        deviceUID: deviceUID,
                        requestedFrameCount: requestedFrameCount,
                        observedFrameCount: observedFrameCount,
                        operation: "verify buffer frame size\(restorationSuffix)"
                    )
                )
            }
        } catch let failure as LegacyRouteFailure {
            throw failure
        } catch {
            let restorationSuffix = immediateBufferRestoreSuffix(
                originalFrameCount,
                deviceUID: deviceUID,
                deviceID: deviceID
            )
            throw LegacyRouteFailure.bufferFrameSizeConfiguration(
                BufferFrameSizeConfigurationContext(
                    deviceUID: deviceUID,
                    requestedFrameCount: requestedFrameCount,
                    observedFrameCount: originalFrameCount,
                    operation: "set buffer frame size\(restorationSuffix)"
                )
            )
        }
        return BufferFrameSizeRestore(
            deviceUID: deviceUID,
            frameCount: originalFrameCount,
            appliedFrameCount: requestedFrameCount
        )
    }

    private func configureAggregateBufferFrameSize(
        _ requestedFrameCount: UInt32,
        aggregateDeviceID: AudioDeviceID
    ) throws {
        do {
            try CoreAudioPropertyReader.writeUInt32(
                requestedFrameCount,
                objectID: aggregateDeviceID,
                address: bufferFrameSizeAddress
            )
            let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: aggregateDeviceID,
                address: bufferFrameSizeAddress
            )
            guard observedFrameCount == requestedFrameCount else {
                throw LegacyRouteFailure.aggregateVerification(
                    "Aggregate buffer frame size mismatch: requested \(requestedFrameCount), observed \(observedFrameCount)"
                )
            }
        } catch let failure as LegacyRouteFailure {
            throw failure
        } catch {
            throw LegacyRouteFailure.aggregateVerification(
                "Failed to configure aggregate buffer frame size to \(requestedFrameCount): \(error.localizedDescription)"
            )
        }
    }

    private func restoreBufferFrameSizes(
        _ restores: [BufferFrameSizeRestore]
    ) -> [String] {
        var failures: [String] = []
        for restore in restores.reversed() {
            do {
                let restoredDeviceID = try deviceID(for: restore.deviceUID)
                let currentFrameCount = try CoreAudioPropertyReader.readUInt32(
                    objectID: restoredDeviceID,
                    address: bufferFrameSizeAddress
                )
                if currentFrameCount == restore.frameCount {
                    continue
                }
                guard currentFrameCount == restore.appliedFrameCount else {
                    legacyCoreAudioLogger.warning(
                        "Not restoring buffer frame size for \(restore.deviceUID.rawValue, privacy: .public) because another client changed it to \(currentFrameCount)"
                    )
                    continue
                }
                try CoreAudioPropertyReader.writeUInt32(
                    restore.frameCount,
                    objectID: restoredDeviceID,
                    address: bufferFrameSizeAddress
                )
                let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                    objectID: restoredDeviceID,
                    address: bufferFrameSizeAddress
                )
                if observedFrameCount != restore.frameCount {
                    failures.append(
                        "restore buffer frame size for \(restore.deviceUID.rawValue): expected \(restore.frameCount), observed \(observedFrameCount)"
                    )
                }
            } catch {
                failures.append(
                    "restore buffer frame size for \(restore.deviceUID.rawValue): \(error.localizedDescription)"
                )
            }
        }
        return failures
    }

    private func immediateBufferRestoreSuffix(
        _ originalFrameCount: UInt32,
        deviceUID: AudioDeviceUID,
        deviceID: AudioDeviceID
    ) -> String {
        do {
            try CoreAudioPropertyReader.writeUInt32(
                originalFrameCount,
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            let observedFrameCount = try CoreAudioPropertyReader.readUInt32(
                objectID: deviceID,
                address: bufferFrameSizeAddress
            )
            guard observedFrameCount == originalFrameCount else {
                let message = "; restoring \(deviceUID.rawValue) to \(originalFrameCount) was not applied (observed \(observedFrameCount))"
                legacyCoreAudioLogger.error("\(message, privacy: .public)")
                return message
            }
            return ""
        } catch {
            let message = "; restoring \(deviceUID.rawValue) to \(originalFrameCount) also failed: \(error.localizedDescription)"
            legacyCoreAudioLogger.error("\(message, privacy: .public)")
            return message
        }
    }
}
