import XCTest
@testable import ScreamBar

final class DirectRoutingBufferDescriptionTests: XCTestCase {
    func testAutomaticBufferIncludesEffectiveTier() {
        XCTAssertEqual(
            DirectRoutingBufferDescription.make(
                configuredSize: .automatic,
                effectiveFrameCount: 64
            ),
            "Automatic · 64 frames active"
        )
    }

    func testExplicitBufferDoesNotRepeatMatchingEffectiveTier() {
        XCTAssertEqual(
            DirectRoutingBufferDescription.make(
                configuredSize: .frames128,
                effectiveFrameCount: 128
            ),
            "128 frames"
        )
    }

    func testExplicitBufferDistinguishesDifferentEffectiveTier() {
        XCTAssertEqual(
            DirectRoutingBufferDescription.make(
                configuredSize: .frames64,
                effectiveFrameCount: 128
            ),
            "64 frames selected · 128 frames active"
        )
    }

    func testMissingEffectiveTierKeepsConfiguredLabel() {
        XCTAssertEqual(
            DirectRoutingBufferDescription.make(
                configuredSize: .automatic,
                effectiveFrameCount: nil
            ),
            "Automatic"
        )
    }
}
