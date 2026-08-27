@testable import ScreamBar
import AudioToolbox
import XCTest

final class AUHALPlaythroughContractTests: XCTestCase {
    func testCorrectIOBusEnablementContract() {
        XCTAssertEqual(AUHALPlaythroughTopology.inputElement, 1)
        XCTAssertEqual(AUHALPlaythroughTopology.outputElement, 0)
        XCTAssertEqual(AUHALPlaythroughTopology.inputEnableScope, kAudioUnitScope_Input)
        XCTAssertEqual(AUHALPlaythroughTopology.outputEnableScope, kAudioUnitScope_Output)
    }

    func testClientFormatIsDeterministicFloat32NonInterleavedPCM() {
        let format = AUHALPlaythrough.makeClientFormat(
            sampleRate: 48_000,
            channelCount: 2
        )

        XCTAssertEqual(format.mSampleRate, 48_000)
        XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(format.mBitsPerChannel, 32)
        XCTAssertNotEqual(format.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertNotEqual(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
    }

    @MainActor
    func testAggregateDescriptionUsesOutputMasterAndInputOnlyDriftCompensation() throws {
        let input = makeDevice(uid: "input")
        let output = makeDevice(uid: "output")
        let description = LegacyCoreAudioBackend.makeAggregateDescription(
            input: input,
            output: output
        )
        let subdevices = try XCTUnwrap(
            description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        )

        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "output")
        XCTAssertEqual(subdevices.count, 2)
        XCTAssertEqual(subdevices[0][kAudioSubDeviceUIDKey] as? String, "output")
        XCTAssertEqual(subdevices[0][kAudioSubDeviceDriftCompensationKey] as? Int, 0)
        XCTAssertEqual(subdevices[1][kAudioSubDeviceUIDKey] as? String, "input")
        XCTAssertEqual(subdevices[1][kAudioSubDeviceDriftCompensationKey] as? Int, 1)
    }

    private func makeDevice(uid: String) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: uid,
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
