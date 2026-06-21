import AppKit
import SwiftUI

struct StatusSectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 16) {
            StatusRow(
                serviceName: "JACK Server",
                status: viewModel.jackService.status,
                onStart: { viewModel.jackService.start(configuration: viewModel.configuration) },
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
                onStart: { viewModel.screamService.start(configuration: viewModel.configuration) },
                onStop: { viewModel.screamService.stop() }
            )

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Slider(value: $viewModel.systemVolume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 20)
            }

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
