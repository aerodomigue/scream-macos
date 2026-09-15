import AppKit

/// Observes dismissal gestures only while an accessory-app popover is open.
@MainActor
final class PopoverDismissalMonitor {
    private static let ESCAPE_KEY_CODE: UInt16 = 53
    private static let MOUSE_EVENTS: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private weak var contentWindow: NSWindow?
    private weak var anchorView: NSView?
    private var onDismiss: (() -> Void)?

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignationObserver { NotificationCenter.default.removeObserver(resignationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    func start(contentWindow: NSWindow, anchorView: NSView, onDismiss: @escaping () -> Void) {
        stop()
        self.contentWindow = contentWindow
        self.anchorView = anchorView
        self.onDismiss = onDismiss
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.MOUSE_EVENTS.union(.keyDown)) { [weak self] event in
            self?.handleLocalEvent(event)
            // The original click must still reach its target, including the anchor's toggle.
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.MOUSE_EVENTS) { [weak self] _ in
            self?.dismiss()
        }
        resignationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignationObserver { NotificationCenter.default.removeObserver(resignationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        localMonitor = nil
        globalMonitor = nil
        resignationObserver = nil
        spaceObserver = nil
        contentWindow = nil
        anchorView = nil
        onDismiss = nil
    }

    func handleLocalEvent(_ event: NSEvent) {
        guard onDismiss != nil else { return }
        if event.type == .keyDown {
            if event.keyCode == Self.ESCAPE_KEY_CODE { dismiss() }
            return
        }
        if let contentWindow, event.window === contentWindow { return }
        if let anchorView, let anchorWindow = anchorView.window, event.window === anchorWindow {
            let point = anchorView.convert(event.locationInWindow, from: nil)
            if NSMouseInRect(point, anchorView.bounds, anchorView.isFlipped) { return }
        }
        dismiss()
    }

    private func dismiss() {
        let action = onDismiss
        stop()
        action?()
    }
}
