@testable import ScreamBar
import XCTest

@MainActor
final class ConfigurationStoreTests: XCTestCase {
    func testJackArgumentsUsePlaybackOnlyMode() {
        let arguments = ScreamConfiguration().buildJackArguments()

        XCTAssertEqual(arguments.prefix(3), ["-d", "coreaudio", "-P"])
    }

    private struct SchemaOneDirectRoutingConfiguration: Encodable {
        let inputSelection = AudioDeviceSelection.systemDefault
        let outputSelection = AudioDeviceSelection.systemDefault
    }

    private struct SchemaOneAppConfiguration: Encodable {
        let schemaVersion = 1
        let mode = ApplicationMode.directRouting
        let scream = ScreamConfiguration()
        let directRouting = SchemaOneDirectRoutingConfiguration()
    }

    private struct PriorDirectRoutingConfiguration: Encodable {
        let inputSelection = AudioDeviceSelection.systemDefault
        let outputSelection = AudioDeviceSelection.systemDefault
        let bufferSize = DirectRoutingBufferSize.frames128
        let sampleRate = "44100"
    }

    private struct PriorAppConfiguration: Encodable {
        let schemaVersion = AppConfiguration.currentSchemaVersion
        let mode = ApplicationMode.directRouting
        let scream = ScreamConfiguration()
        let directRouting = PriorDirectRoutingConfiguration()
    }

    private struct SchemaTwoAppConfiguration: Encodable {
        let schemaVersion = 2
        let mode = ApplicationMode.scream
        let scream = ScreamConfiguration()
        let directRouting = DirectRoutingConfiguration()
        let menuBarDisplay = MenuBarDisplayConfiguration(showFrames: true)
    }

    private struct SchemaThreeAppConfiguration: Encodable {
        let schemaVersion = 3
        let mode: ApplicationMode
        let scream = ScreamConfiguration()
        let directRouting = DirectRoutingConfiguration()
        let menuBarDisplay = MenuBarDisplayConfiguration()
        let wakeOnLAN = WakeOnLANConfiguration()
    }

    func testMigratesLegacyScreamConfigurationWithoutDeletingLegacyValue() throws {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var legacyConfiguration = ScreamConfiguration()
        legacyConfiguration.port = 4_012
        let legacyData = try JSONEncoder().encode(legacyConfiguration)
        userDefaults.set(legacyData, forKey: "screamConfiguration")

        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let migratedConfiguration = store.load()

        XCTAssertEqual(migratedConfiguration.mode, .scream)
        XCTAssertEqual(migratedConfiguration.scream.port, 4_012)
        XCTAssertNotNil(userDefaults.data(forKey: "screamConfiguration"))
        XCTAssertNotNil(userDefaults.data(forKey: "appConfiguration.v1"))
    }

    func testMigratesSchemaOneDirectRoutingBufferSizeToAutomatic() throws {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            try JSONEncoder().encode(SchemaOneAppConfiguration()),
            forKey: "appConfiguration.v1"
        )

        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let migratedConfiguration = store.load()

        XCTAssertEqual(
            migratedConfiguration.schemaVersion,
            AppConfiguration.currentSchemaVersion
        )
        XCTAssertEqual(migratedConfiguration.mode, .directRouting)
        XCTAssertEqual(migratedConfiguration.directRouting.bufferSize, .automatic)
        XCTAssertEqual(
            migratedConfiguration.directRouting.automaticSensitivity,
            .relaxed
        )
        XCTAssertEqual(
            migratedConfiguration.menuBarDisplay,
            MenuBarDisplayConfiguration()
        )
        XCTAssertEqual(
            migratedConfiguration.wakeOnLAN,
            WakeOnLANConfiguration()
        )
    }

    func testRemovedDirectSampleRateSettingIsIgnoredWhenLoadingExistingSettings() throws {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            try JSONEncoder().encode(PriorAppConfiguration()),
            forKey: "appConfiguration.v1"
        )

        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let loadedConfiguration = store.load()

        XCTAssertEqual(loadedConfiguration.mode, .directRouting)
        XCTAssertEqual(loadedConfiguration.directRouting.bufferSize, .frames128)
        XCTAssertEqual(
            loadedConfiguration.directRouting.automaticSensitivity,
            .relaxed
        )
    }

    func testMigratesSchemaTwoWithWakeOnLANDisabledByDefault() throws {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            try JSONEncoder().encode(SchemaTwoAppConfiguration()),
            forKey: "appConfiguration.v1"
        )

        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let migratedConfiguration = store.load()

        XCTAssertEqual(
            migratedConfiguration.schemaVersion,
            AppConfiguration.currentSchemaVersion
        )
        XCTAssertEqual(
            migratedConfiguration.wakeOnLAN,
            WakeOnLANConfiguration()
        )
        XCTAssertTrue(migratedConfiguration.menuBarDisplay.showFrames)
    }

    func testMigratesLegacyAutoStartToSelectedScreamRuntime() throws {
        let migratedConfiguration = try loadSchemaThreeConfiguration(
            mode: .scream,
            legacyAutoStart: true
        )

        XCTAssertEqual(
            migratedConfiguration.audioRuntimeState,
            PersistedAudioRuntimeState(
                jackShouldRun: true,
                screamShouldRun: true
            )
        )
    }

    func testMigratesLegacyAutoStartToSelectedDirectRuntime() throws {
        let migratedConfiguration = try loadSchemaThreeConfiguration(
            mode: .directRouting,
            legacyAutoStart: true
        )

        XCTAssertEqual(
            migratedConfiguration.audioRuntimeState,
            PersistedAudioRuntimeState(directRoutingShouldRun: true)
        )
    }

    func testDisabledLegacyAutoStartMigratesToStoppedRuntime() throws {
        let migratedConfiguration = try loadSchemaThreeConfiguration(
            mode: .directRouting,
            legacyAutoStart: false
        )

        XCTAssertEqual(
            migratedConfiguration.audioRuntimeState,
            PersistedAudioRuntimeState()
        )
    }

    func testAutomaticBufferSensitivityIsPersisted() {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let configuration = AppConfiguration(
            directRouting: DirectRoutingConfiguration(
                automaticSensitivity: .strict
            )
        )

        store.save(configuration)

        XCTAssertEqual(
            store.load().directRouting.automaticSensitivity,
            .strict
        )
    }

    func testMenuBarDisplaySelectionIsPersisted() {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let configuration = AppConfiguration(
            menuBarDisplay: MenuBarDisplayConfiguration(
                showFrames: true,
                showApplicationLatency: true
            )
        )

        store.save(configuration)

        XCTAssertEqual(store.load().menuBarDisplay, configuration.menuBarDisplay)
    }

    func testWakeOnLANConfigurationIsPersisted() {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let configuration = AppConfiguration(
            wakeOnLAN: WakeOnLANConfiguration(
                isEnabled: true,
                macAddress: "00:11:22:33:44:55",
                destination: "10.2.0.0/16"
            )
        )

        store.save(configuration)

        XCTAssertEqual(store.load().wakeOnLAN, configuration.wakeOnLAN)
    }

    func testAudioRuntimeStateIsPersisted() {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        )
        let configuration = AppConfiguration(
            mode: .directRouting,
            audioRuntimeState: PersistedAudioRuntimeState(
                directRoutingShouldRun: true
            )
        )

        store.save(configuration)

        XCTAssertEqual(
            store.load().audioRuntimeState,
            configuration.audioRuntimeState
        )
    }

    private func loadSchemaThreeConfiguration(
        mode: ApplicationMode,
        legacyAutoStart: Bool
    ) throws -> AppConfiguration {
        let suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            throw ConfigurationStoreTestError.userDefaultsUnavailable
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(legacyAutoStart, forKey: "autoStart")
        userDefaults.set(
            try JSONEncoder().encode(SchemaThreeAppConfiguration(mode: mode)),
            forKey: "appConfiguration.v1"
        )

        return ConfigurationStore(
            userDefaults: userDefaults,
            logStore: RollingLogStore()
        ).load()
    }
}

private enum ConfigurationStoreTestError: Error {
    case userDefaultsUnavailable
}
