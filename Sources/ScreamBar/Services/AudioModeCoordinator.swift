import Combine
import Foundation

@MainActor
final class AudioModeCoordinator: ObservableObject {
    typealias CleanupOperation = () async throws -> Void
    typealias StartOperation = () -> Void

    @Published private(set) var transitionError: AudioModeTransitionError?
    @Published private(set) var isTransitioning = false

    private var desiredRevision: UInt64 = 0
    private var transitionTask: Task<Void, Never>?
    private var pendingCleanup: (mode: ApplicationMode, operation: CleanupOperation)?
    private(set) var isShuttingDown = false

    func transition(
        from sourceMode: ApplicationMode,
        to targetMode: ApplicationMode,
        shouldStartTarget: Bool,
        stopSource: @escaping CleanupOperation,
        startTarget: @escaping StartOperation
    ) {
        guard !isShuttingDown else {
            transitionError = .shuttingDown
            return
        }
        desiredRevision &+= 1
        let revision = desiredRevision
        let predecessor = transitionTask
        isTransitioning = true

        transitionTask = Task { [weak self] in
            await predecessor?.value
            guard let self, !self.isShuttingDown else { return }

            if let pendingCleanup = self.pendingCleanup {
                do {
                    try await pendingCleanup.operation()
                    self.pendingCleanup = nil
                } catch {
                    self.transitionError = .cleanupFailed(
                        mode: pendingCleanup.mode,
                        diagnostics: error.localizedDescription
                    )
                    self.finishIfCurrent(revision)
                    return
                }
            }

            do {
                try await stopSource()
            } catch {
                self.pendingCleanup = (sourceMode, stopSource)
                self.transitionError = .cleanupFailed(
                    mode: sourceMode,
                    diagnostics: error.localizedDescription
                )
                self.finishIfCurrent(revision)
                return
            }

            guard revision == self.desiredRevision, !self.isShuttingDown else {
                return
            }
            self.transitionError = nil
            if shouldStartTarget {
                startTarget()
            }
            self.isTransitioning = false
        }
    }

    func waitForIdle() async {
        await transitionTask?.value
    }

    func beginShutdown(
        stopAllModes: @escaping CleanupOperation
    ) async -> [String] {
        guard !isShuttingDown else { return [] }
        isShuttingDown = true
        desiredRevision &+= 1
        await transitionTask?.value
        transitionTask = nil

        var failures: [String] = []
        pendingCleanup = nil
        do {
            try await stopAllModes()
        } catch {
            failures.append(error.localizedDescription)
        }
        isTransitioning = false
        if !failures.isEmpty {
            transitionError = .cleanupFailed(
                mode: .directRouting,
                diagnostics: failures.joined(separator: "; ")
            )
        }
        return failures
    }

    private func finishIfCurrent(_ revision: UInt64) {
        if revision == desiredRevision {
            isTransitioning = false
        }
    }
}
