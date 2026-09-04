@testable import ScreamBar
import XCTest

final class PersistedAudioRuntimeStateTests: XCTestCase {
    func testScreamIntentAlwaysRestoresItsJACKDependency() {
        let state = PersistedAudioRuntimeState(
            jackShouldRun: false,
            screamShouldRun: true
        )

        XCTAssertTrue(state.jackShouldRun)
        XCTAssertTrue(state.screamShouldRun)
    }

    func testLegacyAutoStartIsMigratedOnlyForSelectedMode() {
        XCTAssertEqual(
            PersistedAudioRuntimeState.migrated(
                legacyAutoStart: true,
                selectedMode: .scream
            ),
            PersistedAudioRuntimeState(
                jackShouldRun: true,
                screamShouldRun: true
            )
        )
        XCTAssertEqual(
            PersistedAudioRuntimeState.migrated(
                legacyAutoStart: true,
                selectedMode: .directRouting
            ),
            PersistedAudioRuntimeState(directRoutingShouldRun: true)
        )
        XCTAssertEqual(
            PersistedAudioRuntimeState.migrated(
                legacyAutoStart: false,
                selectedMode: .scream
            ),
            PersistedAudioRuntimeState()
        )
    }

    func testModeUpdatesPreserveTheOtherModesStoredIntent() {
        var state = PersistedAudioRuntimeState(
            jackShouldRun: true,
            screamShouldRun: true
        )

        state.setMode(.directRouting, shouldRun: true)
        XCTAssertTrue(state.jackShouldRun)
        XCTAssertTrue(state.screamShouldRun)
        XCTAssertTrue(state.directRoutingShouldRun)

        state.setMode(.scream, shouldRun: false)
        XCTAssertFalse(state.jackShouldRun)
        XCTAssertFalse(state.screamShouldRun)
        XCTAssertTrue(state.directRoutingShouldRun)
    }

    func testDecodedScreamIntentRestoresJACKDependency() throws {
        let encodedState = Data(
            "{\"jackShouldRun\":false,\"screamShouldRun\":true,\"directRoutingShouldRun\":false}".utf8
        )

        let state = try JSONDecoder().decode(
            PersistedAudioRuntimeState.self,
            from: encodedState
        )

        XCTAssertTrue(state.jackShouldRun)
        XCTAssertTrue(state.screamShouldRun)
    }
}
