import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

private let trustImportLogger = Logger(subsystem: "com.screambar.app", category: "DaemonTrustImport")

private enum DaemonTrustImportError: LocalizedError {
    case targetChanged

    var errorDescription: String? {
        "The selected machine changed during import. Select the intended machine and import its public trust file again."
    }
}

struct DaemonTrustImportView: View {
    let host: String?
    @Binding var trust: HostDaemonTrust?
    @ObservedObject var service: DaemonShutdownService
    let onClose: () -> Void
    let onImportingChanged: (Bool) -> Void
    @State private var bundleText = ""
    @State private var showingFilePicker = false
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Host Daemon")
                .font(.headline)
            Text("On the PC, use hostctl export-trust, or hostctl pairing create for a client key. Import that JSON file or paste its contents below.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Target: \(host ?? "No machine configured")")
                .font(.caption)
            TextEditor(text: $bundleText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 150)
                .border(.secondary.opacity(0.3))
                .privacySensitive()
                .disabled(isImporting)
            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose JSON file…") { showingFilePicker = true }
                    .disabled(isImporting)
                Spacer()
                Button("Cancel") { onClose() }
                    .disabled(isImporting)
                    .keyboardShortcut(.cancelAction)
                Button(isImporting ? "Connecting…" : "Import") {
                    Task { await importBundle() }
                }
                .disabled(isImporting || bundleText.isEmpty || host == nil || service.hasPendingAction)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 510, height: 370)
        .interactiveDismissDisabled(isImporting)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.json, .plainText]) { selection in
            do {
                bundleText = try readBundleFile(selection.get())
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
        .onDisappear { bundleText = "" }
    }

    private func importBundle() async {
        guard !isImporting, !service.hasPendingAction, let host,
              service.beginConfigurationChange() else { return }
        isImporting = true
        onImportingChanged(true)
        importError = nil
        var shouldClose = false
        defer {
            isImporting = false
            onImportingChanged(false)
            service.endConfigurationChange()
            if shouldClose { onClose() }
        }
        do {
            let bundle = try HostDaemonTrustBundle(jsonData: Data(bundleText.utf8))
            let endpoint = try HostDaemonEndpoint(host: host, trust: bundle.trust)
            if let enrollment = bundle.enrollmentToken {
                _ = try await HostDaemonAPIClient().pair(
                    endpoint: endpoint, enrollmentToken: enrollment, clientName: "ScreamBar"
                )
            }
            guard service.configuredHost == host else { throw DaemonTrustImportError.targetChanged }
            trust = bundle.trust
            bundleText = ""
            await service.refresh()
            shouldClose = true
        } catch {
            importError = error.localizedDescription
        }
    }

    private func readBundleFile(_ url: URL) throws -> String {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        let contents: Data
        do {
            contents = try handle.read(upToCount: HostDaemonTrustBundle.MAX_BUNDLE_BYTES + 1) ?? Data()
        } catch {
            let readFailure = error
            do { try handle.close() }
            catch { trustImportLogger.error("Could not close agent trust input: \(error.localizedDescription, privacy: .public)") }
            throw readFailure
        }
        try handle.close()
        guard contents.count <= HostDaemonTrustBundle.MAX_BUNDLE_BYTES,
              let decoded = String(data: contents, encoding: .utf8) else {
            throw HostDaemonClientError.invalidTrustBundle("use a UTF-8 JSON file smaller than 64 KiB.")
        }
        return decoded
    }
}
