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

        XCTAssertEqual(migratedConfiguration.schemaVersion, 2)
        XCTAssertEqual(migratedConfiguration.mode, .directRouting)
        XCTAssertEqual(migratedConfiguration.directRouting.bufferSize, .automatic)
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
    }
}
