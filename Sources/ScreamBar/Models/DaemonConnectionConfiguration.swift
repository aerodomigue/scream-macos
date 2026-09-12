import Foundation

/// Persistent public server identity; client keys remain in Keychain.
struct DaemonConnectionConfiguration: Codable, Equatable, Sendable {
    var trust: HostDaemonTrust?

    init(trust: HostDaemonTrust? = nil) {
        self.trust = trust
    }
}
