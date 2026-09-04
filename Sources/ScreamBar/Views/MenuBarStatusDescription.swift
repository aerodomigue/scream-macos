import Foundation

enum MenuBarStatusDescription {
    static func make(
        configuration: MenuBarDisplayConfiguration,
        routingState: AudioRoutingState
    ) -> String? {
        guard case .running(let route) = routingState else { return nil }

        var components: [String] = []
        if configuration.showFrames,
           let frameCount = route.bufferFrameSize {
            components.append("\(frameCount) frames")
        }
        if configuration.showApplicationLatency,
           let latencySeconds = route.estimatedApplicationLatencySeconds {
            components.append(
                String(format: "%.1f ms", latencySeconds * 1_000)
            )
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }
}
