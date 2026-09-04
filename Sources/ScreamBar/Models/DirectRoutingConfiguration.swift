import Foundation

struct DirectRoutingConfiguration: Codable, Equatable, Sendable {
    var inputSelection: AudioDeviceSelection = .systemDefault
    var outputSelection: AudioDeviceSelection = .systemDefault
    var bufferSize: DirectRoutingBufferSize = .automatic
    var automaticSensitivity: DirectRoutingAutomaticSensitivity = .relaxed

    private enum CodingKeys: String, CodingKey {
        case inputSelection
        case outputSelection
        case bufferSize
        case automaticSensitivity
    }

    init(
        inputSelection: AudioDeviceSelection = .systemDefault,
        outputSelection: AudioDeviceSelection = .systemDefault,
        bufferSize: DirectRoutingBufferSize = .automatic,
        automaticSensitivity: DirectRoutingAutomaticSensitivity = .relaxed
    ) {
        self.inputSelection = inputSelection
        self.outputSelection = outputSelection
        self.bufferSize = bufferSize
        self.automaticSensitivity = automaticSensitivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputSelection = try container.decode(
            AudioDeviceSelection.self,
            forKey: .inputSelection
        )
        outputSelection = try container.decode(
            AudioDeviceSelection.self,
            forKey: .outputSelection
        )
        bufferSize = try container.decodeIfPresent(
            DirectRoutingBufferSize.self,
            forKey: .bufferSize
        ) ?? .automatic
        automaticSensitivity = try container.decodeIfPresent(
            DirectRoutingAutomaticSensitivity.self,
            forKey: .automaticSensitivity
        ) ?? .relaxed
    }
}
