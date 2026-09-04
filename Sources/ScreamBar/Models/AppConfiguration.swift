import Foundation

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    var mode: ApplicationMode
    var scream: ScreamConfiguration
    var directRouting: DirectRoutingConfiguration
    var menuBarDisplay: MenuBarDisplayConfiguration
    var wakeOnLAN: WakeOnLANConfiguration
    var audioRuntimeState: PersistedAudioRuntimeState

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mode
        case scream
        case directRouting
        case menuBarDisplay
        case wakeOnLAN
        case audioRuntimeState
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        mode: ApplicationMode = .scream,
        scream: ScreamConfiguration = ScreamConfiguration(),
        directRouting: DirectRoutingConfiguration = DirectRoutingConfiguration(),
        menuBarDisplay: MenuBarDisplayConfiguration =
            MenuBarDisplayConfiguration(),
        wakeOnLAN: WakeOnLANConfiguration = WakeOnLANConfiguration(),
        audioRuntimeState: PersistedAudioRuntimeState =
            PersistedAudioRuntimeState()
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.scream = scream
        self.directRouting = directRouting
        self.menuBarDisplay = menuBarDisplay
        self.wakeOnLAN = wakeOnLAN
        self.audioRuntimeState = audioRuntimeState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        mode = try container.decode(ApplicationMode.self, forKey: .mode)
        scream = try container.decode(ScreamConfiguration.self, forKey: .scream)
        directRouting = try container.decode(
            DirectRoutingConfiguration.self,
            forKey: .directRouting
        )
        menuBarDisplay = try container.decodeIfPresent(
            MenuBarDisplayConfiguration.self,
            forKey: .menuBarDisplay
        ) ?? MenuBarDisplayConfiguration()
        wakeOnLAN = try container.decodeIfPresent(
            WakeOnLANConfiguration.self,
            forKey: .wakeOnLAN
        ) ?? WakeOnLANConfiguration()
        audioRuntimeState = try container.decodeIfPresent(
            PersistedAudioRuntimeState.self,
            forKey: .audioRuntimeState
        ) ?? PersistedAudioRuntimeState()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mode, forKey: .mode)
        try container.encode(scream, forKey: .scream)
        try container.encode(directRouting, forKey: .directRouting)
        try container.encode(menuBarDisplay, forKey: .menuBarDisplay)
        try container.encode(wakeOnLAN, forKey: .wakeOnLAN)
        try container.encode(audioRuntimeState, forKey: .audioRuntimeState)
    }
}
