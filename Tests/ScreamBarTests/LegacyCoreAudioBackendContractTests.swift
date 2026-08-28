@testable import ScreamBar
import CoreAudio
import XCTest

@MainActor
final class LegacyCoreAudioBackendContractTests: XCTestCase {
    func testAggregateValidationRequiresExactDriftConfiguration() throws {
        let inputUID = AudioDeviceUID(rawValue: "input")
        let outputUID = AudioDeviceUID(rawValue: "output")

        XCTAssertNoThrow(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(uid: outputUID, driftCompensation: 0),
                    AggregateSubdeviceState(uid: inputUID, driftCompensation: 1),
                ],
                expectedInputUID: inputUID,
                expectedOutputUID: outputUID
            )
        )

        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(uid: outputUID, driftCompensation: 1),
                    AggregateSubdeviceState(uid: inputUID, driftCompensation: 1),
                ],
                expectedInputUID: inputUID,
                expectedOutputUID: outputUID
            )
        )
        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(uid: outputUID, driftCompensation: 0),
                    AggregateSubdeviceState(uid: inputUID, driftCompensation: 0),
                ],
                expectedInputUID: inputUID,
                expectedOutputUID: outputUID
            )
        )
    }

    func testAggregateValidationRejectsUnexpectedMembership() {
        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.validateAggregateSubdevices(
                [
                    AggregateSubdeviceState(
                        uid: AudioDeviceUID(rawValue: "output"),
                        driftCompensation: 0
                    ),
                    AggregateSubdeviceState(
                        uid: AudioDeviceUID(rawValue: "unexpected"),
                        driftCompensation: 1
                    ),
                ],
                expectedInputUID: AudioDeviceUID(rawValue: "input"),
                expectedOutputUID: AudioDeviceUID(rawValue: "output")
            )
        )
    }

    func testAggregateCompositionReadbackParsesDriftState() throws {
        let states = try LegacyCoreAudioBackend.aggregateSubdeviceStates(
            from: [
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: "output",
                        kAudioSubDeviceDriftCompensationKey: NSNumber(value: 0),
                    ],
                    [
                        kAudioSubDeviceUIDKey: "input",
                        kAudioSubDeviceDriftCompensationKey: NSNumber(value: 1),
                    ],
                ],
            ]
        )

        XCTAssertEqual(
            states,
            [
                AggregateSubdeviceState(
                    uid: AudioDeviceUID(rawValue: "output"),
                    driftCompensation: 0
                ),
                AggregateSubdeviceState(
                    uid: AudioDeviceUID(rawValue: "input"),
                    driftCompensation: 1
                ),
            ]
        )
    }

    func testAggregateCompositionReadbackRejectsMissingDriftState() {
        XCTAssertThrowsError(
            try LegacyCoreAudioBackend.aggregateSubdeviceStates(
                from: [
                    kAudioAggregateDeviceSubDeviceListKey: [
                        [kAudioSubDeviceUIDKey: "input"],
                    ],
                ]
            )
        )
    }

    func testFailedListenerRemovalIsRetainedAndRetried() {
        var removalStatuses: [OSStatus] = [-7_002, noErr]
        var removalCount = 0
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { _, _, _, _ in
                removalCount += 1
                return removalStatuses.removeFirst()
            },
            isDevicePresent: { _ in true }
        )
        let backend = LegacyCoreAudioBackend(listenerOperations: operations)
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        XCTAssertEqual(backend.stopMonitoring().count, 1)
        XCTAssertEqual(backend.listenerRegistrationCountForTesting, 1)
        XCTAssertTrue(backend.stopMonitoring().isEmpty)
        XCTAssertEqual(backend.listenerRegistrationCountForTesting, 0)
        XCTAssertEqual(removalCount, 2)
    }

    func testDisconnectedDeviceListenerRemovalFailureDoesNotBlockListenerRebuild() throws {
        var presenceResponses = [true, false]
        var removalCount = 0
        let operations = CoreAudioListenerOperations(
            add: { _, _, _, _ in noErr },
            remove: { _, _, _, _ in
                removalCount += 1
                return kAudioHardwareUnspecifiedError
            },
            isDevicePresent: { _ in
                presenceResponses.removeFirst()
            }
        )
        let backend = LegacyCoreAudioBackend(
            listenerOperations: operations,
            allDeviceIDsProvider: { [] }
        )
        backend.installListenerRegistrationForTesting(
            objectID: 42,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        XCTAssertNoThrow(try backend.rebuildListeners())
        XCTAssertEqual(
            backend.listenerRegistrationCountForTesting,
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.count
        )
        XCTAssertEqual(removalCount, 1)
    }

    func testSystemDefaultOutputIsMonitoredDirectly() {
        XCTAssertTrue(
            LegacyCoreAudioBackend.monitoredSystemPropertyAddresses.contains {
                $0.mSelector == kAudioHardwarePropertyDefaultOutputDevice
            }
        )
    }

    func testStreamConfigurationIsMonitoredOnInputAndOutputScopes() {
        let streamAddresses = LegacyCoreAudioBackend.monitoredDevicePropertyAddresses.filter {
            $0.mSelector == kAudioDevicePropertyStreamConfiguration
        }

        XCTAssertEqual(streamAddresses.count, 2)
        XCTAssertEqual(
            Set(streamAddresses.map(\.mScope)),
            Set([kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput])
        )
    }

    func testDuplicateNormalizedNamesUseUIDAsStableTieBreaker() {
        let laterUID = makeDevice(uid: "device.b", name: " Audio Device ")
        let earlierUID = makeDevice(uid: "device.a", name: "audio device")

        let sorted = LegacyCoreAudioBackend.sortedDevices([laterUID, earlierUID])

        XCTAssertEqual(sorted.map(\.id.rawValue), ["device.a", "device.b"])
    }

    private func makeDevice(uid: String, name: String) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: name,
            inputChannelCount: 2,
            outputChannelCount: 2,
            isAlive: true,
            currentNominalSampleRate: 48_000,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 48_000, maximum: 48_000),
            ]
        )
    }
}
