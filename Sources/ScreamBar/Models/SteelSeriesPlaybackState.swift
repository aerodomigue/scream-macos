import Foundation

/// Remembers only a volume muted by this app; zero alone does not imply mute.
struct SteelSeriesPlaybackState: Equatable {
    let volume: SteelSeriesVolume
    private(set) var restoreVolume: SteelSeriesVolume?
    var isMuted: Bool { restoreVolume != nil }

    init(volume: SteelSeriesVolume, restoreVolume: SteelSeriesVolume? = nil) {
        self.volume = volume
        self.restoreVolume = restoreVolume
    }

    func reconciled(with observed: SteelSeriesVolume) -> Self {
        Self(volume: observed, restoreVolume: observed.percentage == 0 ? restoreVolume : nil)
    }

    func applying(_ action: SteelSeriesVolumeAction) -> Self {
        switch action {
        case .adjust(let change):
            // Volume keys leave mute starting from silence, without an unexpected jump.
            return Self(volume: change.applying(to: volume))
        case .toggleMute:
            if let restoreVolume { return Self(volume: restoreVolume) }
            guard volume.percentage > 0 else { return self }
            return Self(volume: volume.adjusted(by: -SteelSeriesVolume.MAX_ATTENUATION), restoreVolume: volume)
        }
    }
}

enum SteelSeriesVolumeAction {
    case adjust(SteelSeriesVolumeChange)
    case toggleMute
}

/// Preserves individual volume steps and their ordering around mute presses.
struct SteelSeriesVolumeActions {
    private static let MAX_PENDING_ACTIONS = 128
    private var actions: [SteelSeriesVolumeAction] = []
    var isEmpty: Bool { actions.isEmpty }
    var containsMute: Bool {
        actions.contains {
            if case .toggleMute = $0 { return true }
            return false
        }
    }

    mutating func append(step: Int) -> Bool {
        guard actions.count < Self.MAX_PENDING_ACTIONS else { return false }
        var change = SteelSeriesVolumeChange()
        change.append(step)
        actions.append(.adjust(change))
        return true
    }

    mutating func appendMute() -> Bool {
        // Two consecutive toggles cancel, without generating redundant USB writes.
        if case .toggleMute = actions.last {
            actions.removeLast()
            return true
        }
        guard actions.count < Self.MAX_PENDING_ACTIONS else { return false }
        actions.append(.toggleMute)
        return true
    }

    mutating func popFirst() -> SteelSeriesVolumeAction? {
        guard !actions.isEmpty else { return nil }
        return actions.removeFirst()
    }

    func applying(to state: SteelSeriesPlaybackState) -> SteelSeriesPlaybackState {
        actions.reduce(state) { $0.applying($1) }
    }
}
