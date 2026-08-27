import Foundation

struct DirectRoutingConfiguration: Codable, Equatable, Sendable {
    var inputSelection: AudioDeviceSelection = .systemDefault
    var outputSelection: AudioDeviceSelection = .systemDefault
    var bufferSize: DirectRoutingBufferSize = .automatic

    private enum CodingKeys: String, CodingKey {
        case inputSelection
        case outputSelection
        case bufferSize
    }

    init(
        inputSelection: AudioDeviceSelection = .systemDefault,
        outputSelection: AudioDeviceSelection = .systemDefault,
        bufferSize: DirectRoutingBufferSize = .automatic
    ) {
        self.inputSelection = inputSelection
        self.outputSelection = outputSelection
        self.bufferSize = bufferSize
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
    }
}
