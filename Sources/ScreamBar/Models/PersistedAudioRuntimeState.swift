import Foundation

struct PersistedAudioRuntimeState: Codable, Equatable, Sendable {
    var jackShouldRun: Bool
    var screamShouldRun: Bool
    var directRoutingShouldRun: Bool

    init(
        jackShouldRun: Bool = false,
        screamShouldRun: Bool = false,
        directRoutingShouldRun: Bool = false
    ) {
        self.jackShouldRun = jackShouldRun || screamShouldRun
        self.screamShouldRun = screamShouldRun
        self.directRoutingShouldRun = directRoutingShouldRun
    }

    mutating func setScreamRuntime(
        jackShouldRun: Bool,
        screamShouldRun: Bool
    ) {
        self.jackShouldRun = jackShouldRun || screamShouldRun
        self.screamShouldRun = screamShouldRun
    }

    mutating func setMode(_ mode: ApplicationMode, shouldRun: Bool) {
        switch mode {
        case .scream:
            setScreamRuntime(
                jackShouldRun: shouldRun,
                screamShouldRun: shouldRun
            )
        case .directRouting:
            directRoutingShouldRun = shouldRun
        }
    }

    static func migrated(
        legacyAutoStart: Bool,
        selectedMode: ApplicationMode
    ) -> Self {
        guard legacyAutoStart else { return Self() }
        switch selectedMode {
        case .scream:
            return Self(jackShouldRun: true, screamShouldRun: true)
        case .directRouting:
            return Self(directRoutingShouldRun: true)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case jackShouldRun
        case screamShouldRun
        case directRoutingShouldRun
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            jackShouldRun: try container.decodeIfPresent(
                Bool.self,
                forKey: .jackShouldRun
            ) ?? false,
            screamShouldRun: try container.decodeIfPresent(
                Bool.self,
                forKey: .screamShouldRun
            ) ?? false,
            directRoutingShouldRun: try container.decodeIfPresent(
                Bool.self,
                forKey: .directRoutingShouldRun
            ) ?? false
        )
    }
}
