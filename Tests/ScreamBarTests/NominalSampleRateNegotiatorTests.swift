@testable import ScreamBar
import XCTest

final class NominalSampleRateNegotiatorTests: XCTestCase {
    private let inputUID = AudioDeviceUID(rawValue: "test.input")
    private let outputUID = AudioDeviceUID(rawValue: "test.output")

    func testPrefersCurrentOutputRateWhenCommon() throws {
        let selectedRate = try negotiate(
            inputRanges: [range(44_100), range(48_000)],
            outputRanges: [range(44_100), range(48_000)],
            outputCurrentRate: 44_100
        )

        XCTAssertEqual(selectedRate, 44_100)
    }

    func testPrefersFortyEightKilohertzThenFortyFourPointOne() throws {
        let preferredRate = try negotiate(
            inputRanges: [range(44_100), range(48_000)],
            outputRanges: [range(44_100), range(48_000)],
            outputCurrentRate: 96_000
        )
        let secondaryRate = try negotiate(
            inputRanges: [range(44_100)],
            outputRanges: [range(44_100), range(48_000)],
            outputCurrentRate: 96_000
        )

        XCTAssertEqual(preferredRate, 48_000)
        XCTAssertEqual(secondaryRate, 44_100)
    }

    func testChoosesDeterministicNearestCommonRate() throws {
        let selectedRate = try negotiate(
            inputRanges: [range(32_000), range(64_000)],
            outputRanges: [range(32_000), range(64_000)],
            outputCurrentRate: 96_000
        )

        XCTAssertEqual(selectedRate, 32_000)
    }

    func testIntersectsContinuousRanges() throws {
        let selectedRate = try negotiate(
            inputRanges: [NominalSampleRateRange(minimum: 40_000, maximum: 50_000)],
            outputRanges: [NominalSampleRateRange(minimum: 47_000, maximum: 52_000)],
            outputCurrentRate: 51_000
        )

        XCTAssertEqual(selectedRate, 48_000)
    }

    func testNoCommonRateThrowsDedicatedError() {
        XCTAssertThrowsError(
            try negotiate(
                inputRanges: [range(44_100)],
                outputRanges: [range(48_000)],
                outputCurrentRate: 48_000
            )
        ) { error in
            guard case AudioRoutingError.noCommonSampleRate(let context) = error else {
                return XCTFail("Expected noCommonSampleRate, received \(error)")
            }
            XCTAssertEqual(context.inputUID, self.inputUID)
            XCTAssertEqual(context.outputUID, self.outputUID)
        }
    }

    func testEquivalentReorderedRangesNormalizeToSameSnapshotValue() {
        let first = [
            NominalSampleRateRange(minimum: 48_000, maximum: 96_000),
            NominalSampleRateRange(minimum: 44_100, maximum: 48_000),
        ]
        let reorderedAndSplit = [
            NominalSampleRateRange(minimum: 60_000, maximum: 96_000),
            NominalSampleRateRange(minimum: 44_100, maximum: 60_000),
        ]

        XCTAssertEqual(
            NominalSampleRateNegotiator.normalizedRanges(first),
            NominalSampleRateNegotiator.normalizedRanges(reorderedAndSplit)
        )
    }

    private func negotiate(
        inputRanges: [NominalSampleRateRange],
        outputRanges: [NominalSampleRateRange],
        outputCurrentRate: Double
    ) throws -> Double {
        try NominalSampleRateNegotiator.negotiate(
            inputRanges: inputRanges,
            outputRanges: outputRanges,
            outputCurrentRate: outputCurrentRate,
            inputUID: inputUID,
            outputUID: outputUID
        )
    }

    private func range(_ rate: Double) -> NominalSampleRateRange {
        NominalSampleRateRange(minimum: rate, maximum: rate)
    }
}
