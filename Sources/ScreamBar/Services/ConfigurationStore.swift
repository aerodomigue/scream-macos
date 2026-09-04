import Foundation
import os

private let configurationLogger = Logger(
    subsystem: "com.screambar.app",
    category: "ConfigurationStore"
)

private enum ConfigurationStoreError: LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported settings schema version: \(version)"
        }
    }
}

@MainActor
final class ConfigurationStore {
    private static let appConfigurationKey = "appConfiguration.v1"
    private static let legacyScreamConfigurationKey = "screamConfiguration"
    private static let legacyAutoStartKey = "autoStart"

    private let userDefaults: UserDefaults
    private weak var logStore: RollingLogStore?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard, logStore: RollingLogStore) {
        self.userDefaults = userDefaults
        self.logStore = logStore
    }

    func load() -> AppConfiguration {
        if let encodedConfiguration = userDefaults.data(forKey: Self.appConfigurationKey) {
            do {
                let configuration = try decoder.decode(AppConfiguration.self, from: encodedConfiguration)
                guard configuration.schemaVersion <= AppConfiguration.currentSchemaVersion else {
                    throw ConfigurationStoreError.unsupportedSchemaVersion(configuration.schemaVersion)
                }
                if configuration.schemaVersion < AppConfiguration.currentSchemaVersion {
                    let migratedRuntimeState: PersistedAudioRuntimeState
                    if configuration.schemaVersion < 4 {
                        migratedRuntimeState = .migrated(
                            legacyAutoStart: userDefaults.bool(
                                forKey: Self.legacyAutoStartKey
                            ),
                            selectedMode: configuration.mode
                        )
                    } else {
                        migratedRuntimeState = configuration.audioRuntimeState
                    }
                    let migratedConfiguration = AppConfiguration(
                        mode: configuration.mode,
                        scream: configuration.scream,
                        directRouting: configuration.directRouting,
                        menuBarDisplay: configuration.menuBarDisplay,
                        wakeOnLAN: configuration.wakeOnLAN,
                        audioRuntimeState: migratedRuntimeState
                    )
                    save(migratedConfiguration)
                    report(
                        "Migrated application settings from schema \(configuration.schemaVersion) to \(AppConfiguration.currentSchemaVersion)"
                    )
                    return migratedConfiguration
                }
                return configuration
            } catch {
                report("Failed to load application settings: \(error.localizedDescription)")
            }
        }

        guard let legacyData = userDefaults.data(forKey: Self.legacyScreamConfigurationKey) else {
            return AppConfiguration()
        }

        do {
            let legacyConfiguration = try decoder.decode(ScreamConfiguration.self, from: legacyData)
            let migratedConfiguration = AppConfiguration(scream: legacyConfiguration)
            save(migratedConfiguration)
            report("Migrated legacy Scream settings")
            return migratedConfiguration
        } catch {
            report("Failed to migrate legacy Scream settings: \(error.localizedDescription)")
            return AppConfiguration()
        }
    }

    func save(_ configuration: AppConfiguration) {
        do {
            let encodedConfiguration = try encoder.encode(configuration)
            let legacyScreamConfiguration = try encoder.encode(configuration.scream)
            userDefaults.set(encodedConfiguration, forKey: Self.appConfigurationKey)
            userDefaults.set(legacyScreamConfiguration, forKey: Self.legacyScreamConfigurationKey)
        } catch {
            report("Failed to save application settings: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        configurationLogger.error("\(message, privacy: .public)")
        logStore?.append(source: .app, message: message)
    }
}
