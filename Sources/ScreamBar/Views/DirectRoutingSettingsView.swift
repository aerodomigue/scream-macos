import SwiftUI

struct DirectRoutingSettingsView: View {
    @Binding var configuration: DirectRoutingConfiguration
    @ObservedObject var deviceService: CoreAudioDeviceService
    @ObservedObject var routingService: DirectAudioRoutingService

    var body: some View {
        Section("Audio Routing") {
            Picker("Input", selection: $configuration.inputSelection) {
                Text(defaultInputLabel).tag(AudioDeviceSelection.systemDefault)
                ForEach(deviceService.inputDevices) { device in
                    Text(device.name).tag(
                        AudioDeviceSelection.device(
                            uid: device.id,
                            lastKnownName: device.name
                        )
                    )
                }
                unavailableInputOption
            }

            Picker("Output", selection: $configuration.outputSelection) {
                Text(defaultOutputLabel).tag(AudioDeviceSelection.systemDefault)
                ForEach(deviceService.outputDevices) { device in
                    Text(device.name).tag(
                        AudioDeviceSelection.device(
                            uid: device.id,
                            lastKnownName: device.name
                        )
                    )
                }
                unavailableOutputOption
            }

            Picker("Buffer size", selection: $configuration.bufferSize) {
                ForEach(DirectRoutingBufferSize.allCases, id: \.self) { bufferSize in
                    Text(bufferSize.label).tag(bufferSize)
                }
            }

            HStack {
                Text("Automatic sensitivity")
                Spacer()
                Picker("", selection: $configuration.automaticSensitivity) {
                    ForEach(
                        DirectRoutingAutomaticSensitivity.allCases,
                        id: \.self
                    ) { sensitivity in
                        Text(sensitivity.label).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(configuration.bufferSize != .automatic)
            }

            Text(
                configuration.bufferSize == .automatic
                    ? configuration.automaticSensitivity.helpText
                    : "Select Automatic buffer size to enable sensitivity."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Lower values reduce latency but may cause audio dropouts. Automatic is recommended for Bluetooth devices.")
                .font(.caption)
                .foregroundStyle(.secondary)

            routingStatus
        }
    }

    private var defaultInputLabel: String {
        guard let uid = deviceService.snapshot.defaultInputUID,
              let device = deviceService.snapshot.device(withUID: uid) else {
            return "Default Input"
        }
        return "Default Input — \(device.name)"
    }

    private var defaultOutputLabel: String {
        guard let uid = deviceService.snapshot.defaultOutputUID,
              let device = deviceService.snapshot.device(withUID: uid) else {
            return "System Default"
        }
        return "System Default — \(device.name)"
    }

    @ViewBuilder
    private var unavailableInputOption: some View {
        if case .device(let uid, let lastKnownName) = configuration.inputSelection,
           deviceService.snapshot.device(withUID: uid) == nil {
            Text("\(lastKnownName) — unavailable")
                .tag(configuration.inputSelection)
        }
    }

    @ViewBuilder
    private var unavailableOutputOption: some View {
        if case .device(let uid, let lastKnownName) = configuration.outputSelection,
           deviceService.snapshot.device(withUID: uid) == nil {
            Text("\(lastKnownName) — unavailable")
                .tag(configuration.outputSelection)
        }
    }

    @ViewBuilder
    private var routingStatus: some View {
        switch routingService.state {
        case .running(let route):
            let bufferDescription = DirectRoutingBufferDescription.make(
                configuredSize: configuration.bufferSize,
                effectiveFrameCount: route.bufferFrameSize,
                automaticSensitivity: configuration.automaticSensitivity
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("\(route.input.name) → \(route.output.name)")
                Text(sampleRateDescription(route))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Buffer: \(bufferDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let latencyDescription = applicationLatencyDescription(route) {
                    Text(latencyDescription)
                        .font(.caption)
                        .foregroundStyle(
                            route.isLowLatency ? Color.secondary : Color.orange
                        )
                }
                if route.isUsingOutputFallback {
                    Text("Preferred output unavailable — using System Default")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .waitingForInput:
            Text("Waiting for the selected input device")
                .font(.caption)
                .foregroundStyle(.orange)
        case .waitingForOutput:
            Text("Waiting for an output device")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let error):
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.red)
        case .stopped, .starting, .reconfiguring, .stopping:
            EmptyView()
        }
    }

    private func sampleRateDescription(_ route: EffectiveAudioRoute) -> String {
        if route.usesSampleRateConversion {
            return "\(Int(route.inputNominalSampleRate)) → \(Int(route.outputNominalSampleRate)) Hz — converted"
        }
        return "\(Int(route.nominalSampleRate)) Hz"
    }

    private func applicationLatencyDescription(
        _ route: EffectiveAudioRoute
    ) -> String? {
        guard route.usesSampleRateConversion,
              let latencySeconds = route.estimatedApplicationLatencySeconds else {
            return nil
        }
        let latencyMilliseconds = latencySeconds * 1_000
        if route.isLowLatency,
           latencySeconds
            <= AsyncSRCBufferSizing.preferredApplicationLatencySeconds {
            return String(
                format: "App-added latency ≈ %.1f ms (target ≤ 5 ms)",
                latencyMilliseconds
            )
        }
        if route.isLowLatency {
            return String(
                format: "App-added latency ≈ %.1f ms (stable, max 10 ms)",
                latencyMilliseconds
            )
        }
        return String(
            format: "Low-latency fallback — app-added latency ≈ %.1f ms",
            latencyMilliseconds
        )
    }
}
