import Foundation

struct AudioBufferFrameSizeRange: Codable, Equatable, Sendable {
    let minimum: UInt32
    let maximum: UInt32

    func contains(_ frameCount: UInt32) -> Bool {
        frameCount >= minimum && frameCount <= maximum
    }
}
