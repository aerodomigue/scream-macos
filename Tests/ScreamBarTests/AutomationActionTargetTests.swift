@testable import ScreamBar
import XCTest

final class AutomationActionTargetTests: XCTestCase {
    func testAudioTargetOnlyIncludesAudio() {
        XCTAssertTrue(AutomationActionTarget.audio.includesAudio)
        XCTAssertFalse(AutomationActionTarget.audio.includesWakeOnLAN)
    }

    func testWakeOnLANTargetOnlyIncludesWakeOnLAN() {
        XCTAssertFalse(AutomationActionTarget.wakeOnLAN.includesAudio)
        XCTAssertTrue(AutomationActionTarget.wakeOnLAN.includesWakeOnLAN)
    }

    func testCombinedTargetIncludesBothActions() {
        XCTAssertTrue(AutomationActionTarget.audioAndWakeOnLAN.includesAudio)
        XCTAssertTrue(
            AutomationActionTarget.audioAndWakeOnLAN.includesWakeOnLAN
        )
    }

    func testTargetRawValuesRoundTripForPersistence() throws {
        for target in AutomationActionTarget.allCases {
            let encodedTarget = try JSONEncoder().encode(target)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    AutomationActionTarget.self,
                    from: encodedTarget
                ),
                target
            )
        }
    }
}
