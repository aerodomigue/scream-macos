import Foundation

enum DirectRoutingBufferDescription {
    static func make(
        configuredSize: DirectRoutingBufferSize,
        effectiveFrameCount: UInt32?
    ) -> String {
        guard let effectiveFrameCount else {
            return configuredSize.label
        }

        if configuredSize == .automatic {
            return "Automatic · \(effectiveFrameCount) frames active"
        }

        guard configuredSize.frameCount != effectiveFrameCount else {
            return "\(effectiveFrameCount) frames"
        }

        return "\(configuredSize.label) selected · \(effectiveFrameCount) frames active"
    }
}
