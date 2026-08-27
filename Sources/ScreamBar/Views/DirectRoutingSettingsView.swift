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
            VStack(alignment: .leading, spacing: 3) {
                Text("\(route.input.name) → \(route.output.name)")
                Text("\(Int(route.nominalSampleRate)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
