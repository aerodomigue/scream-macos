import Foundation

enum DirectRoutingBufferSize: String, Codable, CaseIterable, Sendable {
    case automatic
    case frames64
    case frames128
    case frames256
    case frames512
    case frames1024
    case frames2048

    var frameCount: UInt32? {
        switch self {
        case .automatic:
            return nil
        case .frames64:
            return 64
        case .frames128:
            return 128
        case .frames256:
            return 256
        case .frames512:
            return 512
        case .frames1024:
            return 1_024
        case .frames2048:
            return 2_048
        }
    }

    var label: String {
        guard let frameCount else { return "Automatic" }
        return "\(frameCount) frames"
    }
}
