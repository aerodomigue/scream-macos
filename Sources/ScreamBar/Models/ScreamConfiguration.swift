import Foundation

enum ToggleScope: String, Codable, CaseIterable {
    case screamOnly
    case all

    var label: String {
        switch self {
        case .screamOnly: return "Scream only"
        case .all: return "Scream + JACK"
        }
    }
}

struct ScreamConfiguration: Codable, Equatable {
    var useUnicast: Bool = false
    var port: Int = 4010
    var toggleScope: ToggleScope = .screamOnly
    var jackSampleRate: Int? = 48000
    var jackBufferFrames: Int? = 1024

    static let sampleRateOptions = [44100, 48000, 88200, 96000, 192000]
    static let bufferFramesOptions = [64, 128, 256, 512, 1024, 2048]

    func buildArguments() -> [String] {
        var arguments = ["-o", "jack"]

        if useUnicast {
            arguments.append("-u")
            if port != 4010 {
                arguments += ["-p", String(port)]
            }
        }

        return arguments
    }

    func buildJackArguments() -> [String] {
        var arguments = ["-d", "coreaudio"]
        if let jackSampleRate {
            arguments += ["-r", String(jackSampleRate)]
        }
        if let jackBufferFrames {
            arguments += ["-p", String(jackBufferFrames)]
        }
        return arguments
    }
}
