import AppKit

/// Uses one image so AppKit applies the same inactive-display tint to icon and text.
@MainActor
enum SteelSeriesMenuBarImage {
    private static let ICON_SIZE: CGFloat = 14
    private static let ICON_SPACING: CGFloat = 5
    private static let FONT = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    )

    static func make(batteryText: String, description: String) -> NSImage? {
        guard let icon = MenuBarSymbol.image(
            name: "headphones", color: .white, description: "Headset"
        ) else { return nil }
        let title = NSAttributedString(string: batteryText, attributes: [
            .font: FONT,
            .foregroundColor: NSColor.white,
        ])
        let titleSize = title.size()
        let size = NSSize(
            width: ICON_SIZE + ICON_SPACING + ceil(titleSize.width),
            height: ceil(max(ICON_SIZE, titleSize.height))
        )
        let image = NSImage(size: size, flipped: false) { bounds in
            icon.draw(in: NSRect(
                x: 0, y: (bounds.height - ICON_SIZE) / 2,
                width: ICON_SIZE, height: ICON_SIZE
            ))
            title.draw(at: NSPoint(
                x: ICON_SIZE + ICON_SPACING, y: (bounds.height - titleSize.height) / 2
            ))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }
}
