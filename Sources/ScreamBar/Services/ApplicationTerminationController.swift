import AppKit
import Foundation

@MainActor
final class ApplicationTerminationController {
    static let shared = ApplicationTerminationController()

    weak var viewModel: AppViewModel?

    private init() {}
}

@MainActor
final class ScreamBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false
    private var cleanupCompleted = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if cleanupCompleted {
            return .terminateNow
        }
        guard !terminationInProgress,
              let viewModel = ApplicationTerminationController.shared.viewModel else {
            return terminationInProgress ? .terminateLater : .terminateNow
        }

        terminationInProgress = true
        Task { @MainActor [weak self, weak sender] in
            await viewModel.performTerminalShutdown()
            guard let self, let sender else { return }
            self.cleanupCompleted = true
            self.terminationInProgress = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
