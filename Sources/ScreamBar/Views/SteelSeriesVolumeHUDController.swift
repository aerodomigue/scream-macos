import AppKit
import Combine
import SwiftUI

/// Presents key-driven feedback without taking focus or polling the USB device.
@MainActor
final class SteelSeriesVolumeHUDController {
    private static let DISMISS_DELAY: TimeInterval = 1.5
    private static let SCREEN_INSET: CGFloat = 12
    private var panel: NSPanel?
    private var content: NSHostingView<SteelSeriesVolumeHUDView>?
    private var dismissalTimer: Timer?
    private var presentationTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private let dismissDelay: TimeInterval
    private(set) var isVisible = false

    init(service: SteelSeriesVolumeKeyService, dismissDelay: TimeInterval? = nil) {
        self.dismissDelay = dismissDelay ?? Self.DISMISS_DELAY
        service.keyFeedback.sink { [weak self, weak service] active in
            guard let self else { return }
            if active {
                guard presentationTask == nil else { return }
                // Leave the keyboard event callback before creating or displaying a window.
                presentationTask = Task { @MainActor [weak self, weak service] in
                    guard let self, !Task.isCancelled else { return }
                    presentationTask = nil
                    show(volume: service?.volume, isMuted: service?.isMuted ?? false)
                }
            } else { hide() }
        }.store(in: &subscriptions)
        service.$volume.combineLatest(service.$isMuted).sink { [weak self] volume, isMuted in
            guard let self, isVisible else { return }
            guard let volume else { hide(); return }
            content?.rootView = SteelSeriesVolumeHUDView(volume: volume, isMuted: isMuted)
        }.store(in: &subscriptions)
    }

    deinit {
        dismissalTimer?.invalidate()
        presentationTask?.cancel()
        let panel = panel
        Task { @MainActor in panel?.orderOut(nil) }
    }

    private func show(volume: SteelSeriesVolume?, isMuted: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        if panel == nil { createPanel() }
        guard let panel else { return }
        if !isVisible {
            content?.rootView = SteelSeriesVolumeHUDView(volume: volume, isMuted: isMuted)
            panel.setFrame(Self.frame(in: screen.visibleFrame), display: true)
            panel.orderFrontRegardless()
            isVisible = true
        }
        if let dismissalTimer {
            // Reuse the same timer during key repeat; never accumulate delayed tasks.
            dismissalTimer.fireDate = Date(timeIntervalSinceNow: dismissDelay)
        } else {
            let timer = Timer(timeInterval: dismissDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
            dismissalTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func hide() {
        presentationTask?.cancel()
        presentationTask = nil
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        panel?.orderOut(nil)
        isVisible = false
    }

    static func frame(in visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.maxX - SteelSeriesVolumeHUDView.WIDTH - SCREEN_INSET,
               y: visibleFrame.maxY - SteelSeriesVolumeHUDView.HEIGHT - SCREEN_INSET,
               width: SteelSeriesVolumeHUDView.WIDTH, height: SteelSeriesVolumeHUDView.HEIGHT)
    }

    private func createPanel() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: SteelSeriesVolumeHUDView(volume: nil))
        panel.contentView = content
        self.content = content
        self.panel = panel
    }
}
