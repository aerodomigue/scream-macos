import AppKit
import SwiftUI

/// Owns the import window independently of the transient menu bar presentation.
@MainActor
final class DaemonTrustImportWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    private static let CONTENT_SIZE = NSSize(width: 510, height: 370)
    private var isImporting = false

    init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Daemon import windows are created programmatically.")
    }

    func present(host: String, trust: Binding<HostDaemonTrust?>, service: DaemonShutdownService) {
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            activate(window)
            return
        }
        guard !service.hasPendingAction, !service.isBusy else { return }

        let importWindow = prepareWindow(host: host, trust: trust, service: service)
        importWindow.center()
        activate(importWindow)
    }

    /// Builds a fresh presentation without ordering it onto the screen.
    func prepareWindow(host: String, trust: Binding<HostDaemonTrust?>, service: DaemonShutdownService) -> NSWindow {
        let importWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.CONTENT_SIZE),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        importWindow.title = "Connect to Host Daemon"
        importWindow.isReleasedWhenClosed = false
        importWindow.isRestorable = false
        importWindow.tabbingMode = .disallowed
        importWindow.delegate = self
        importWindow.contentViewController = NSHostingController(rootView: DaemonTrustImportView(
            host: host,
            trust: trust,
            service: service,
            onClose: { [weak self] in self?.window?.performClose(nil) },
            onImportingChanged: { [weak self] in self?.isImporting = $0 }
        ))
        window = importWindow
        return importWindow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isImporting
    }

    func windowWillClose(_ notification: Notification) {
        // Release the editor and its enrollment text when this presentation ends.
        window?.contentViewController = nil
    }

    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
