import AppKit
import Combine
import SwiftUI

@MainActor
final class SteelSeriesMenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    private static let AUTOSAVE_NAME = "SteelSeriesOmniBattery"
    private static let POPOVER_WIDTH: CGFloat = 310
    private let service: SteelSeriesHeadsetService
    private let volumeHUD: SteelSeriesVolumeHUDController
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let dismissalMonitor = PopoverDismissalMonitor()
    private var subscription: AnyCancellable?

    init(service: SteelSeriesHeadsetService) {
        self.service = service
        self.volumeHUD = SteelSeriesVolumeHUDController(service: service.volumeKeys)
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: SteelSeriesStatusView(service: service).frame(width: Self.POPOVER_WIDTH)
        )
        subscription = service.$state.sink { [weak self] state in
            self?.update(state)
        }
    }

    private func update(_ state: SteelSeriesHeadsetState) {
        guard state != .disabled else {
            closePopover()
            statusItem?.isVisible = false
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // An independent, named item keeps its position when moved with Command-drag.
            item.autosaveName = Self.AUTOSAVE_NAME
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.imagePosition = .imageOnly
            item.button?.title = ""
            statusItem = item
        }
        statusItem?.isVisible = true
        let description = "SteelSeries Omni: \(state.connectionDescription). Headset: \(state.headsetBatteryText). Battery in base: \(state.baseBatteryText)."
        statusItem?.button?.image = SteelSeriesMenuBarImage.make(
            batteryText: state.headsetBatteryText, description: description
        )
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel(description)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            service.volumeKeys.setDisplayVisible(.headsetPopover, visible: popover.isShown)
            if popover.isShown, let contentWindow = popover.contentViewController?.view.window {
                dismissalMonitor.start(contentWindow: contentWindow, anchorView: button) { [weak self] in
                    self?.closePopover()
                }
            }
        }
    }

    private func closePopover() {
        service.volumeKeys.setDisplayVisible(.headsetPopover, visible: false)
        dismissalMonitor.stop()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        service.volumeKeys.setDisplayVisible(.headsetPopover, visible: false)
        dismissalMonitor.stop()
    }
}
