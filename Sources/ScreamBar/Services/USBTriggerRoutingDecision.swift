import Foundation

enum USBTriggerRuntimeAction: Equatable {
    case screamOnly
    case screamAndJack
    case directRouting
}

enum USBTriggerRoutingDecision {
    static func startAction(
        mode: ApplicationMode,
        screamToggleScope: ToggleScope
    ) -> USBTriggerRuntimeAction {
        action(mode: mode, screamToggleScope: screamToggleScope)
    }

    static func stopAction(
        mode: ApplicationMode,
        screamToggleScope: ToggleScope
    ) -> USBTriggerRuntimeAction {
        action(mode: mode, screamToggleScope: screamToggleScope)
    }

    private static func action(
        mode: ApplicationMode,
        screamToggleScope: ToggleScope
    ) -> USBTriggerRuntimeAction {
        switch mode {
        case .directRouting:
            return .directRouting
        case .scream:
            return screamToggleScope == .all ? .screamAndJack : .screamOnly
        }
    }
}
