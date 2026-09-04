@testable import ScreamBar
import Foundation
import XCTest

@MainActor
final class TriggerSettingsPersistenceTests: XCTestCase {
    func testGlobalShortcutLayoutDefaultsToCombinedAndPersistsSelection() throws {
        let suiteName = "TriggerSettingsPersistenceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let service = HotkeyService(userDefaults: userDefaults)
        XCTAssertEqual(service.layout, .combined)

        service.layout = .separate

        let restoredService = HotkeyService(userDefaults: userDefaults)
        XCTAssertEqual(restoredService.layout, .separate)
    }

    func testUSBActionTargetDefaultsToAudioAndPersistsSelection() throws {
        let suiteName = "TriggerSettingsPersistenceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let service = USBWatcherService(userDefaults: userDefaults)
        XCTAssertEqual(service.actionTarget, .audio)

        service.actionTarget = .audioAndWakeOnLAN

        let restoredService = USBWatcherService(userDefaults: userDefaults)
        XCTAssertEqual(restoredService.actionTarget, .audioAndWakeOnLAN)
    }
}
