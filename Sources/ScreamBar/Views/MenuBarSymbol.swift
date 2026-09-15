import AppKit

enum MenuBarSymbol {
    @MainActor
    static func image(name: String, color: NSColor, description: String) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: name, accessibilityDescription: description
        ) else { return nil }
        // Bake the tint into a non-template image so the menu bar preserves it.
        let tintedImage = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            color.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        tintedImage.isTemplate = false
        tintedImage.accessibilityDescription = description
        return tintedImage
    }
}
