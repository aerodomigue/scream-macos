import SwiftUI

struct DaemonSettingsView: View {
    @Binding var trust: HostDaemonTrust?
    let host: String?
    @ObservedObject var service: DaemonShutdownService
    @EnvironmentObject private var importWindowController: DaemonTrustImportWindowController
    @State private var settingsError: String?

    var body: some View {
        Section("Shutdown agent") {
            if let trust {
                Text("HTTPS \(host ?? "Select a machine IP"):\(trust.port)")
                    .font(.caption)
                Text("Agent \(trust.daemonID.uuidString.lowercased())")
                    .font(.caption2)
                    .textSelection(.enabled)
            } else {
                Text("Import the trust JSON exported by Host Daemon on the PC. Client pairing is optional unless required by the agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(trust == nil ? "Import agent…" : "Import trust or pairing…") {
                    guard let host else { return }
                    settingsError = nil
                    importWindowController.present(host: host, trust: $trust, service: service)
                }
                .disabled(host == nil || service.hasPendingAction || service.isBusy)
                if trust != nil {
                    Button("Check") {
                        Task { await service.refresh() }
                    }
                    .disabled(service.isBusy || service.hasPendingAction)
                    Button("Forget") { forgetIdentity() }
                        .disabled(service.hasPendingAction || service.isBusy)
                }
            }
            if host == nil {
                Text("Enter the machine IPv4 address and prefix in Wake on LAN first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = settingsError ?? service.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let description = service.statusDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func forgetIdentity() {
        guard !service.hasPendingAction, !service.isBusy else { return }
        do {
            if let host, let trust {
                try HostDaemonCredentialStore().remove(for: HostDaemonEndpoint(host: host, trust: trust))
            }
            trust = nil
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }
}
