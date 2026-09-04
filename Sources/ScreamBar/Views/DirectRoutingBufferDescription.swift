import Foundation

enum DirectRoutingBufferDescription {
    static func make(
        configuredSize: DirectRoutingBufferSize,
        effectiveFrameCount: UInt32?,
        automaticSensitivity: DirectRoutingAutomaticSensitivity? = nil
    ) -> String {
        let automaticLabel = automaticSensitivity.map {
            "Automatic \($0.label)"
        } ?? "Automatic"
        guard let effectiveFrameCount else {
            return configuredSize == .automatic
                ? automaticLabel
                : configuredSize.label
        }

        if configuredSize == .automatic {
            return "\(automaticLabel) · \(effectiveFrameCount) frames active"
        }

        guard configuredSize.frameCount != effectiveFrameCount else {
            return "\(effectiveFrameCount) frames"
        }

        return "\(configuredSize.label) selected · \(effectiveFrameCount) frames active"
    }
}
