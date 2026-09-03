import AppKit
import SwiftUI

struct StatusSectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.applicationMode == .scream {
                screamStatus
            } else {
                directRoutingStatus
            }
            if let transitionError = viewModel.audioModeCoordinator.transitionError {
                Text(transitionError.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private var screamStatus: some View {
        VStack(spacing: 16) {
            StatusRow(
                serviceName: "JACK Server",
                status: viewModel.jackService.status,
                onStart: { viewModel.startJack() },
                onStop: {
                    if NSEvent.modifierFlags.contains(.shift) {
                        viewModel.jackService.forceStop()
                    } else {
                        viewModel.jackService.stop()
                    }
                }
            )

            StatusRow(
                serviceName: "Scream Receiver",
                status: viewModel.screamService.status,
                onStart: { viewModel.startScream() },
                onStop: { viewModel.screamService.stop() }
            )

            Divider()

            HStack(spacing: 12) {
                Button("Start All") {
                    viewModel.startAll()
                }
                .disabled(viewModel.jackService.status == .running && viewModel.screamService.status == .running)

                Button("Stop All") {
                    viewModel.stopAll(force: NSEvent.modifierFlags.contains(.shift))
                }
                .disabled(viewModel.jackService.status == .stopped && viewModel.screamService.status == .stopped)
            }
        }
        .padding(16)
    }

    private var directRoutingStatus: some View {
        VStack(spacing: 16) {
            HStack {
                Circle()
                    .fill(statusColor(for: viewModel.directRoutingService.state.processStatus))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Direct Routing")
                        .font(.headline)
                    Text(directRoutingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if viewModel.directRoutingService.desiredRunning {
                    Button("Stop") {
                        viewModel.stopActiveMode()
                    }
                } else {
                    Button("Start") {
                        viewModel.startActiveMode()
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
    }

    private var directRoutingDescription: String {
        switch viewModel.directRoutingService.state {
        case .running(let route):
            let fallbackSuffix = route.isUsingOutputFallback ? " (fallback)" : ""
            let rateDescription = route.usesSampleRateConversion
                ? "\(Int(route.inputNominalSampleRate)) → \(Int(route.outputNominalSampleRate)) Hz · converted"
                : "\(Int(route.nominalSampleRate)) Hz"
            let bufferDescription = DirectRoutingBufferDescription.make(
                configuredSize: viewModel.directRoutingConfiguration.bufferSize,
                effectiveFrameCount: route.bufferFrameSize
            )
            let latencySuffix: String
            if route.usesSampleRateConversion,
               let latencySeconds = route.estimatedApplicationLatencySeconds {
                latencySuffix = String(
                    format: " · app ≈ %.1f ms",
                    latencySeconds * 1_000
                )
            } else {
                latencySuffix = ""
            }
            return "\(route.input.name) → \(route.output.name)\(fallbackSuffix)\n\(rateDescription)\n\(bufferDescription)\(latencySuffix)"
        case .waitingForInput:
            return "Waiting for input"
        case .waitingForOutput:
            return "Waiting for output"
        default:
            return viewModel.directRoutingService.state.processStatus.label
        }
    }

    private func statusColor(for status: ProcessStatus) -> Color {
        switch status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .stopped: return .red
        case .error: return .orange
        }
    }
}

private struct StatusRow: View {
    let serviceName: String
    let status: ProcessStatus
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(serviceName)
                    .font(.headline)
                Text(status.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if status.isActive {
                Button("Stop") { onStop() }
                    .disabled(status == .stopping)
            } else {
                Button("Start") { onStart() }
                    .disabled(status == .starting)
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .stopped: return .red
        case .error: return .orange
        }
    }
}
