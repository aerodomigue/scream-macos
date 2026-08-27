@testable import ScreamBar
import XCTest

final class BufferFrameSizeValidatorTests: XCTestCase {
    func testAcceptsFrameCountSupportedByBothDevices() throws {
        try BufferFrameSizeValidator.validate(
            requestedFrameCount: 128,
            input: makeDevice(uid: "input", minimum: 64, maximum: 512),
            output: makeDevice(uid: "output", minimum: 128, maximum: 1_024)
        )
    }

    func testRejectsFrameCountOutsideEitherDeviceRange() {
        XCTAssertThrowsError(
            try BufferFrameSizeValidator.validate(
                requestedFrameCount: 64,
                input: makeDevice(uid: "input", minimum: 64, maximum: 512),
                output: makeDevice(uid: "output", minimum: 128, maximum: 1_024)
            )
        ) { error in
            guard case AudioRoutingError.unsupportedBufferFrameSize(let context) = error else {
                return XCTFail("Expected unsupportedBufferFrameSize, received \(error)")
            }
            XCTAssertEqual(context.requestedFrameCount, 64)
        }
    }

    private func makeDevice(
        uid: String,
        minimum: UInt32,
        maximum: UInt32
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: uid,
            inputChannelCount: 2,
            outputChannelCount: 2,
            isAlive: true,
            currentNominalSampleRate: 48_000,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 48_000, maximum: 48_000),
            ],
            currentBufferFrameSize: 256,
            supportedBufferFrameSizeRange: AudioBufferFrameSizeRange(
                minimum: minimum,
                maximum: maximum
            )
        )
    }
}
