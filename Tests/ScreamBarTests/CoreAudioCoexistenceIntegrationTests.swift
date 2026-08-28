@testable import ScreamBar
import AVFAudio
import CoreAudio
import XCTest

@MainActor
final class CoreAudioCoexistenceIntegrationTests: XCTestCase {
    private static let integrationEnvironmentKey = "SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS"

    func testSingleAUHALPlaythroughCanBeCreatedForAFullDuplexDevice() throws {
        try requireHardwareIntegrationTests()
        let backend = LegacyCoreAudioBackend()
        let snapshot = try backend.makeSnapshot(revision: 1)
        guard let device = snapshot.devices.first(where: {
            $0.supportsInput
                && $0.supportsOutput
                && $0.inputChannelCount == $0.outputChannelCount
        }) else {
            throw XCTSkip("No equal-channel full-duplex CoreAudio device is available")
        }
        let deviceID = try resolveDeviceID(uid: device.id)
        let playthrough = try AUHALPlaythrough.make(
            deviceID: deviceID,
            inputChannelCount: device.inputChannelCount,
            inputChannelOffset: 0,
            outputChannelCount: device.outputChannelCount,
            nominalSampleRate: device.currentNominalSampleRate
        )

        let cleanupFailures = playthrough.stopAndDispose()
        XCTAssertTrue(cleanupFailures.isEmpty, cleanupFailures.joined(separator: ", "))
    }

    func testDirectRoutingPreservesDefaultAndHogStateWhileAnotherClientRuns() async throws {
        try requireHardwareIntegrationTests()
        let backend = LegacyCoreAudioBackend()
        let initialSnapshot = try backend.makeSnapshot(revision: 1)
        guard let outputUID = initialSnapshot.defaultOutputUID else {
            throw XCTSkip("No default CoreAudio output is available")
        }
        let outputDeviceID = try resolveDeviceID(uid: outputUID)
        let initialHogOwner = try readHogOwner(deviceID: outputDeviceID)
        let service = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend
        )
        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )
        defer {
            do {
                try service.stopAndDestroyRoute(sessionID: route.sessionID)
            } catch {
                XCTFail("Route cleanup failed: \(error)")
            }
            service.shutdown()
        }

        try service.startRoute(route)
        let concurrentEngine = AVAudioEngine()
        let outputNode = concurrentEngine.outputNode
        concurrentEngine.connect(
            concurrentEngine.mainMixerNode,
            to: outputNode,
            format: outputNode.inputFormat(forBus: 0)
        )
        concurrentEngine.prepare()
        try concurrentEngine.start()
        defer { concurrentEngine.stop() }

        let activeSnapshot = try backend.makeSnapshot(revision: 2)
        let activeHogOwner = try readHogOwner(deviceID: outputDeviceID)
        XCTAssertEqual(activeSnapshot.defaultOutputUID, outputUID)
        XCTAssertEqual(activeHogOwner, initialHogOwner)
        XCTAssertTrue(concurrentEngine.isRunning)
    }

    func testExplicitBufferFrameSizeIsAppliedAndRestored() async throws {
        try requireHardwareIntegrationTests()
        let backend = LegacyCoreAudioBackend()
        let initialSnapshot = try backend.makeSnapshot(revision: 1)
        guard let inputUID = initialSnapshot.defaultInputUID,
              let outputUID = initialSnapshot.defaultOutputUID,
              let input = initialSnapshot.device(withUID: inputUID),
              let output = initialSnapshot.device(withUID: outputUID),
              let inputOriginalFrameCount = input.currentBufferFrameSize,
              let outputOriginalFrameCount = output.currentBufferFrameSize,
              let inputRange = input.supportedBufferFrameSizeRange,
              let outputRange = output.supportedBufferFrameSizeRange else {
            throw XCTSkip("Default devices do not expose buffer frame metadata")
        }
        let candidates = DirectRoutingBufferSize.allCases.compactMap(\.frameCount)
        guard let requestedFrameCount = candidates.first(where: {
            inputRange.contains($0)
                && outputRange.contains($0)
                && $0 != inputOriginalFrameCount
                && $0 != outputOriginalFrameCount
        }) else {
            throw XCTSkip("No alternate common buffer frame size is available")
        }

        let service = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend
        )
        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault,
            requestedBufferFrameSize: requestedFrameCount
        )
        var requiresCleanup = true
        defer {
            if requiresCleanup {
                do {
                    try service.stopAndDestroyRoute(sessionID: route.sessionID)
                } catch {
                    XCTFail("Route cleanup failed: \(error)")
                }
            }
            service.shutdown()
        }

        try service.startRoute(route)
        let activeSnapshot = try backend.makeSnapshot(revision: 2)
        XCTAssertEqual(
            activeSnapshot.device(withUID: inputUID)?.currentBufferFrameSize,
            requestedFrameCount
        )
        XCTAssertEqual(
            activeSnapshot.device(withUID: outputUID)?.currentBufferFrameSize,
            requestedFrameCount
        )

        try service.stopAndDestroyRoute(sessionID: route.sessionID)
        requiresCleanup = false
        let restoredSnapshot = try backend.makeSnapshot(revision: 3)
        XCTAssertEqual(
            restoredSnapshot.device(withUID: inputUID)?.currentBufferFrameSize,
            inputOriginalFrameCount
        )
        XCTAssertEqual(
            restoredSnapshot.device(withUID: outputUID)?.currentBufferFrameSize,
            outputOriginalFrameCount
        )
    }

    func testDirectRoutingTeardownReleasesAllRouteResources() async throws {
        try requireHardwareIntegrationTests()
        let backend = LegacyCoreAudioBackend()
        let service = CoreAudioDeviceService(
            logStore: RollingLogStore(),
            backend: backend
        )
        var sessionID: UUID?
        defer {
            if let sessionID {
                do {
                    try service.stopAndDestroyRoute(sessionID: sessionID)
                } catch {
                    XCTFail("Route cleanup failed: \(error)")
                }
            }
            service.shutdown()
        }

        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )
        sessionID = route.sessionID
        try service.startRoute(route)
        try service.stopAndDestroyRoute(sessionID: route.sessionID)
        sessionID = nil
        XCTAssertNoThrow(try service.confirmRouteResourcesReleased())
    }

    private func requireHardwareIntegrationTests() throws {
        guard ProcessInfo.processInfo.environment[Self.integrationEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.integrationEnvironmentKey)=1 after granting audio-input permission"
            )
        }
    }

    private func resolveDeviceID(uid: AudioDeviceUID) throws -> AudioDeviceID {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let devices = try CoreAudioPropertyReader.readDeviceIDs(
            objectID: systemObjectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        for deviceID in devices {
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
                continue
            }
        }
        throw CoreAudioBackendFailure(
            operation: "Resolve integration-test output",
            status: kAudioHardwareBadDeviceError
        )
    }

    private func readHogOwner(deviceID: AudioDeviceID) throws -> UInt32 {
        try CoreAudioPropertyReader.readUInt32(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyHogMode,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }
}
