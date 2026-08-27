import Foundation

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var mode: ApplicationMode
    var scream: ScreamConfiguration
    var directRouting: DirectRoutingConfiguration

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        mode: ApplicationMode = .scream,
        scream: ScreamConfiguration = ScreamConfiguration(),
        directRouting: DirectRoutingConfiguration = DirectRoutingConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.scream = scream
        self.directRouting = directRouting
    }
}
