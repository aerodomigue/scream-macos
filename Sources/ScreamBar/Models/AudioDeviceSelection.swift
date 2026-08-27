import Foundation

struct AudioDeviceUID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

enum AudioDeviceSelection: Codable, Equatable, Hashable, Sendable {
    case systemDefault
    case device(uid: AudioDeviceUID, lastKnownName: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case uid
        case lastKnownName
    }

    private enum Kind: String, Codable {
        case systemDefault
        case device
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .systemDefault:
            self = .systemDefault
        case .device:
            self = .device(
                uid: try container.decode(AudioDeviceUID.self, forKey: .uid),
                lastKnownName: try container.decode(String.self, forKey: .lastKnownName)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDefault:
            try container.encode(Kind.systemDefault, forKey: .kind)
        case .device(let uid, let lastKnownName):
            try container.encode(Kind.device, forKey: .kind)
            try container.encode(uid, forKey: .uid)
            try container.encode(lastKnownName, forKey: .lastKnownName)
        }
    }
}
