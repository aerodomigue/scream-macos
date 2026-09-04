@testable import ScreamBar
import AudioToolbox
import XCTest

final class AudioHardwareStreamFormatTests: XCTestCase {
    func testIntegerPCMFormatHasHumanReadableStatusAndASBDDescription() {
        let format = AudioHardwareStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsSignedInteger,
            bitsPerChannel: 16,
            bytesPerFrame: 4,
            framesPerPacket: 1,
            bytesPerPacket: 4
        )

        XCTAssertEqual(format.statusDescription, "48000 Hz · 2 ch · 16-bit Integer")
        XCTAssertTrue(format.diagnosticDescription.contains("formatID: 'lpcm'"))
        XCTAssertTrue(format.diagnosticDescription.contains("bits: 16"))
        XCTAssertTrue(format.diagnosticDescription.contains("bytesPerFrame: 4"))
    }

    func testFloatPCMFormatUsesFloatBitDepthInStatus() {
        let format = AudioHardwareStreamFormat(
            sampleRate: 44_100,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat,
            bitsPerChannel: 32,
            bytesPerFrame: 4,
            framesPerPacket: 1,
            bytesPerPacket: 4
        )

        XCTAssertEqual(format.statusDescription, "44100 Hz · 2 ch · Float32")
    }
}
