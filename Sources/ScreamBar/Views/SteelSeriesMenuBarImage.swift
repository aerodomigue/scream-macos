import AppKit

/// Keeps battery warning colors on the headset while preserving the white percentage.
@MainActor
enum SteelSeriesMenuBarImage {
    private static let ICON_SIZE: CGFloat = 14
    private static let ICON_SPACING: CGFloat = 5
    private static let LOW_BATTERY_THRESHOLD = 20
    private static let CRITICAL_BATTERY_THRESHOLD = 10
    private static let FONT = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    )

    static func make(state: SteelSeriesHeadsetState, description: String) -> NSImage? {
        guard let icon = MenuBarSymbol.image(
            name: "headphones", color: iconColor(percentage: state.status?.headsetBattery), description: "Headset"
        ) else { return nil }
        let title = NSAttributedString(string: state.headsetBatteryText, attributes: [
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

    private static func iconColor(percentage: Int?) -> NSColor {
        guard let percentage else { return .white }
        if percentage < CRITICAL_BATTERY_THRESHOLD { return .systemRed }
        if percentage < LOW_BATTERY_THRESHOLD { return .systemOrange }
        return .white
    }
}
