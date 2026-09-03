@testable import ScreamBar
import XCTest

@MainActor
final class RollingLogStoreTests: XCTestCase {
    func testEntriesMatchingSourcesReturnsOnlySelectedSources() {
        let logStore = RollingLogStore()
        logStore.append(source: .app, message: "Application event")
        logStore.append(source: .jack, message: "JACK event")
        logStore.append(source: .routing, message: "Routing event")

        let entries = logStore.entries(matching: [.app, .routing])

        XCTAssertEqual(entries.map(\.source), [.app, .routing])
    }
}
