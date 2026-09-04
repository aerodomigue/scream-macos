@testable import ScreamBar
import XCTest

final class GlobalShortcutLayoutTests: XCTestCase {
    func testCombinedLayoutRoutesPrimaryShortcutToBothActions() {
        XCTAssertEqual(
            GlobalShortcutLayout.combined.primaryAction,
            .audioAndWakeOnLAN
        )
        XCTAssertNil(GlobalShortcutLayout.combined.wakeOnLANAction)
    }

    func testSeparateLayoutRoutesEachShortcutIndependently() {
        XCTAssertEqual(GlobalShortcutLayout.separate.primaryAction, .audio)
        XCTAssertEqual(
            GlobalShortcutLayout.separate.wakeOnLANAction,
            .wakeOnLAN
        )
    }

    func testLayoutRawValuesRoundTripForPersistence() throws {
        for layout in GlobalShortcutLayout.allCases {
            let encodedLayout = try JSONEncoder().encode(layout)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    GlobalShortcutLayout.self,
                    from: encodedLayout
                ),
                layout
            )
        }
    }
}
