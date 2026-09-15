import SwiftUI

/// Compact volume indicator matching the supplied macOS HUD reference.
struct SteelSeriesVolumeHUDView: View {
    static let WIDTH: CGFloat = 294
    static let HEIGHT: CGFloat = 64
    private static let CORNER_RADIUS: CGFloat = 24
    private static let HORIZONTAL_PADDING: CGFloat = 16
    private static let TITLE_SIZE: CGFloat = 12
    private static let ICON_SIZE: CGFloat = 11
    private static let TRACK_HEIGHT: CGFloat = 4
    private static let TICK_COUNT = 17
    private static let TICK_SIZE: CGFloat = 2
    let volume: SteelSeriesVolume?
    let isMuted: Bool

    init(volume: SteelSeriesVolume?, isMuted: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Arctis Nova Pro Omni")
                .font(.system(size: Self.TITLE_SIZE, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 10)
                GeometryReader { geometry in
                    VStack(spacing: 3) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            if let volume {
                                Capsule().fill(.white.opacity(0.9))
                                    .frame(width: geometry.size.width * CGFloat(volume.percentage) / 100)
                            }
                        }
                        .frame(height: Self.TRACK_HEIGHT)
                        HStack(spacing: 0) {
                            ForEach(0..<Self.TICK_COUNT, id: \.self) { index in
                                Circle().fill(.white.opacity(0.09))
                                    .frame(width: Self.TICK_SIZE, height: Self.TICK_SIZE)
                                if index < Self.TICK_COUNT - 1 { Spacer(minLength: 0) }
                            }
                        }
                    }
                }
                .frame(height: 9)
                Image(systemName: "speaker.wave.3.fill")
                    .frame(width: 18)
            }
            .font(.system(size: Self.ICON_SIZE))
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, Self.HORIZONTAL_PADDING)
        .frame(width: Self.WIDTH, height: Self.HEIGHT)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: Self.CORNER_RADIUS))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.CORNER_RADIUS))
        .overlay {
            RoundedRectangle(cornerRadius: Self.CORNER_RADIUS)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Arctis Nova Pro Omni volume")
        .accessibilityValue(isMuted ? "Muted" : volume.map { "\($0.percentage)%" } ?? "Reading volume")
    }
}
