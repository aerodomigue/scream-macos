import SwiftUI

struct WakeOnLANStatusView: View {
    @ObservedObject var wakeService: WakeOnLANService
    @ObservedObject var shutdownService: DaemonShutdownService
    let configuration: WakeOnLANConfiguration

    private var hostIsOnline: Bool {
        wakeService.reachability == .online || shutdownService.isReachable
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text("Wake on LAN")
                    .font(.headline)
                Text(reachabilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let description = shutdownService.statusDescription,
                   hostIsOnline || shutdownService.hasPendingAction {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if hostIsOnline && !shutdownService.isConfigured {
                    Text("Import agent trust in Settings to enable shutdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = visibleError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if shutdownService.canAcknowledgeUnknownOutcome {
                    Text("Clearing this result does not cancel shutdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                powerButton
                if shutdownService.canAcknowledgeUnknownOutcome {
                    Button("Clear result") {
                        shutdownService.acknowledgeUnknownOutcome()
                    }
                    .font(.caption)
                    .help("Clear the unknown result. This does not cancel an issued shutdown.")
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var powerButton: some View {
        if shutdownService.hasPendingAction && !(shutdownService.isAwaitingHostRestart && !hostIsOnline) {
            Button(shutdownService.isAwaitingHostRestart ? "Shutting down…"
                   : shutdownService.canCancel ? "Cancel shutdown" : "Shutdown pending") {
                Task { await shutdownService.cancelShutdown() }
            }
            .disabled(!shutdownService.canCancel || shutdownService.isBusy)
        } else if hostIsOnline {
            Button(shutdownService.canShutdown ? "Shutdown"
                   : shutdownService.isCheckingAgent ? "Checking agent…" : "Agent unavailable") {
                Task { await shutdownService.shutdown() }
            }
            .disabled(!shutdownService.canShutdown || wakeService.isSending)
            .help("Ask the agent to shut down this PC after \(DaemonShutdownService.SHUTDOWN_DELAY_SECONDS) seconds.")
        } else {
            Button("Send Magic Packet") {
                Task { await wakeService.sendMagicPacket() }
            }
            .disabled(!wakeService.isMagicPacketSendEnabled)
        }
    }

    private var visibleError: String? {
        if (hostIsOnline || shutdownService.hasPendingAction),
           let error = shutdownService.lastError { return error }
        return wakeService.lastError
    }

    private var reachabilityDescription: String {
        let destination = wakeService.monitoredHostDescription ?? configuration.destination
        if hostIsOnline { return "\(destination) is online" }
        switch wakeService.reachability {
        case .online:
            return "\(destination) is online"
        case .offline:
            return "\(destination) — no ping response"
        case .unavailable:
            if wakeService.configurationErrorDescription != nil {
                return "Complete the WOL configuration in Settings"
            }
            if let resolved = try? WakeOnLANDestination(configuration.destination), resolved.monitoredHost == nil {
                return "Ready — reachability unavailable for subnet destinations"
            }
            return "\(destination) — status unavailable"
        }
    }

    private var statusColor: Color {
        if hostIsOnline { return .green }
        return wakeService.reachability == .offline ? .red : .secondary
    }
}
