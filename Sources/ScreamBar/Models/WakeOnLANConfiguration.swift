import Foundation

struct WakeOnLANConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var macAddress: String
    var destination: String

    init(
        isEnabled: Bool = false,
        macAddress: String = "",
        destination: String = ""
    ) {
        self.isEnabled = isEnabled
        self.macAddress = macAddress
        self.destination = destination
    }
}
