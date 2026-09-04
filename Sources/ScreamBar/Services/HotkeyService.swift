import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleScream = Self("toggleScream")
    static let sendWakeOnLAN = Self("sendWakeOnLAN")
}

private let hotkeyEnabledKey = "hotkeyEnabled"
private let hotkeyLayoutKey = "hotkeyLayout"

/// Manages global keyboard shortcuts for audio and Wake-on-LAN actions.
@MainActor
final class HotkeyService: ObservableObject {
    var onAction: ((GlobalShortcutAction) -> Void)?

    private let userDefaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: hotkeyEnabledKey)
            updateListening()
        }
    }

    @Published var layout: GlobalShortcutLayout {
        didSet {
            userDefaults.set(layout.rawValue, forKey: hotkeyLayoutKey)
            updateListening()
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.bool(forKey: hotkeyEnabledKey)
        self.layout = Self.loadLayout(from: userDefaults)

        KeyboardShortcuts.onKeyUp(for: .toggleScream) { [weak self] in
            Task { @MainActor in
                self?.handlePrimaryShortcut()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .sendWakeOnLAN) { [weak self] in
            Task { @MainActor in
                self?.handleWakeOnLANShortcut()
            }
        }
        updateListening()
    }

    private func updateListening() {
        guard isEnabled else {
            KeyboardShortcuts.disable(.toggleScream, .sendWakeOnLAN)
            return
        }

        KeyboardShortcuts.enable(.toggleScream)
        switch layout {
        case .combined:
            KeyboardShortcuts.disable(.sendWakeOnLAN)
        case .separate:
            KeyboardShortcuts.enable(.sendWakeOnLAN)
        }
    }

    private func handlePrimaryShortcut() {
        guard isEnabled else { return }
        onAction?(layout.primaryAction)
    }

    private func handleWakeOnLANShortcut() {
        guard isEnabled, let action = layout.wakeOnLANAction else { return }
        onAction?(action)
    }

    private static func loadLayout(
        from userDefaults: UserDefaults
    ) -> GlobalShortcutLayout {
        guard let rawValue = userDefaults.string(forKey: hotkeyLayoutKey),
              let layout = GlobalShortcutLayout(rawValue: rawValue) else {
            return .combined
        }
        return layout
    }
}
