@testable import ScreamBar
import XCTest

@MainActor
final class AudioModeCoordinatorTests: XCTestCase {
    func testScreamToDirectWaitsForConfirmedSourceShutdown() async {
        let coordinator = AudioModeCoordinator()
        let cleanupStarted = expectation(description: "source cleanup started")
        let cleanup = ControlledModeCleanup(onStart: { cleanupStarted.fulfill() })
        var startedModes: [ApplicationMode] = []

        coordinator.transition(
            from: .scream,
            to: .directRouting,
            shouldStartTarget: true,
            stopSource: { try await cleanup.run() },
            startTarget: { startedModes.append(.directRouting) }
        )

        await fulfillment(of: [cleanupStarted])
        XCTAssertTrue(startedModes.isEmpty)
        cleanup.succeed()
        await coordinator.waitForIdle()

        XCTAssertEqual(startedModes, [.directRouting])
        XCTAssertNil(coordinator.transitionError)
    }

    func testDirectToScreamDoesNotStartAfterUnsafeCleanupFailure() async {
        let coordinator = AudioModeCoordinator()
        var startedModes: [ApplicationMode] = []

        coordinator.transition(
            from: .directRouting,
            to: .scream,
            shouldStartTarget: true,
            stopSource: { throw InjectedModeCleanupFailure() },
            startTarget: { startedModes.append(.scream) }
        )
        await coordinator.waitForIdle()

        XCTAssertTrue(startedModes.isEmpty)
        XCTAssertEqual(
            coordinator.transitionError,
            .cleanupFailed(mode: .directRouting, diagnostics: "Injected cleanup failure")
        )
    }

    func testScreamToDirectDoesNotStartWhenOwnedProcessCannotTerminate() async {
        let coordinator = AudioModeCoordinator()
        var startedModes: [ApplicationMode] = []

        coordinator.transition(
            from: .scream,
            to: .directRouting,
            shouldStartTarget: true,
            stopSource: { throw ProcessTerminationFailure.timedOut(pid: 4_242) },
            startTarget: { startedModes.append(.directRouting) }
        )
        await coordinator.waitForIdle()

        XCTAssertTrue(startedModes.isEmpty)
        guard case .cleanupFailed(let mode, let diagnostics) = coordinator.transitionError else {
            return XCTFail("Expected a domain-level process cleanup error")
        }
        XCTAssertEqual(mode, .scream)
        XCTAssertTrue(diagnostics.contains("4242"))
    }

    func testRapidScreamDirectScreamStartsOnlyLatestTarget() async {
        let coordinator = AudioModeCoordinator()
        let cleanupStarted = expectation(description: "first cleanup started")
        let firstCleanup = ControlledModeCleanup(onStart: { cleanupStarted.fulfill() })
        var startedModes: [ApplicationMode] = []

        coordinator.transition(
            from: .scream,
            to: .directRouting,
            shouldStartTarget: true,
            stopSource: { try await firstCleanup.run() },
            startTarget: { startedModes.append(.directRouting) }
        )
        await fulfillment(of: [cleanupStarted])

        coordinator.transition(
            from: .directRouting,
            to: .scream,
            shouldStartTarget: true,
            stopSource: {},
            startTarget: { startedModes.append(.scream) }
        )
        firstCleanup.succeed()
        await coordinator.waitForIdle()

        XCTAssertEqual(startedModes, [.scream])
    }

    func testFailedCleanupIsRetriedBeforeLaterTransitionCanStart() async {
        let coordinator = AudioModeCoordinator()
        var cleanupAttempts = 0
        var startedModes: [ApplicationMode] = []
        let cleanup: AudioModeCoordinator.CleanupOperation = {
            cleanupAttempts += 1
            if cleanupAttempts == 1 {
                throw InjectedModeCleanupFailure()
            }
        }

        coordinator.transition(
            from: .scream,
            to: .directRouting,
            shouldStartTarget: true,
            stopSource: cleanup,
            startTarget: { startedModes.append(.directRouting) }
        )
        await coordinator.waitForIdle()
        XCTAssertTrue(startedModes.isEmpty)

        coordinator.transition(
            from: .directRouting,
            to: .scream,
            shouldStartTarget: true,
            stopSource: {},
            startTarget: { startedModes.append(.scream) }
        )
        await coordinator.waitForIdle()

        XCTAssertEqual(cleanupAttempts, 2)
        XCTAssertEqual(startedModes, [.scream])
    }
}

@MainActor
private final class ControlledModeCleanup {
    private let onStart: () -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func run() async throws {
        onStart()
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

private struct InjectedModeCleanupFailure: LocalizedError {
    var errorDescription: String? { "Injected cleanup failure" }
}
