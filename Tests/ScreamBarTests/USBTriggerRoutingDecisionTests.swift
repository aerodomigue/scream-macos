@testable import ScreamBar
import XCTest

final class USBTriggerRoutingDecisionTests: XCTestCase {
    func testScreamOnlyScopeControlsOnlyScreamForUSBStartAndStop() {
        XCTAssertEqual(
            USBTriggerRoutingDecision.startAction(
                mode: .scream,
                screamToggleScope: .screamOnly
            ),
            .screamOnly
        )
        XCTAssertEqual(
            USBTriggerRoutingDecision.stopAction(
                mode: .scream,
                screamToggleScope: .screamOnly
            ),
            .screamOnly
        )
    }

    func testAllScopeControlsJACKAndScreamForUSBStartAndStop() {
        XCTAssertEqual(
            USBTriggerRoutingDecision.startAction(
                mode: .scream,
                screamToggleScope: .all
            ),
            .screamAndJack
        )
        XCTAssertEqual(
            USBTriggerRoutingDecision.stopAction(
                mode: .scream,
                screamToggleScope: .all
            ),
            .screamAndJack
        )
    }

    func testDirectModeUSBAlwaysControlsDirectRouting() {
        for scope in ToggleScope.allCases {
            XCTAssertEqual(
                USBTriggerRoutingDecision.startAction(
                    mode: .directRouting,
                    screamToggleScope: scope
                ),
                .directRouting
            )
            XCTAssertEqual(
                USBTriggerRoutingDecision.stopAction(
                    mode: .directRouting,
                    screamToggleScope: scope
                ),
                .directRouting
            )
        }
    }
}
