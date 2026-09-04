import Foundation

struct MenuBarDisplayConfiguration: Codable, Equatable, Sendable {
    var showFrames: Bool
    var showApplicationLatency: Bool

    init(
        showFrames: Bool = false,
        showApplicationLatency: Bool = false
    ) {
        self.showFrames = showFrames
        self.showApplicationLatency = showApplicationLatency
    }
}
