import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleScream = Self("toggleScream")
}

private let hotkeyEnabledKey = "hotkeyEnabled"

/// Manages a global keyboard shortcut for toggling Scream services.
@MainActor
final class HotkeyService: ObservableObject {
    var onToggle: (() -> Void)?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: hotkeyEnabledKey)
            updateListening()
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: hotkeyEnabledKey)
        updateListening()
    }

    private func updateListening() {
        if isEnabled {
            KeyboardShortcuts.onKeyUp(for: .toggleScream) { [weak self] in
                Task { @MainActor in
                    self?.onToggle?()
                }
            }
        } else {
            KeyboardShortcuts.disable(.toggleScream)
        }
    }
}
