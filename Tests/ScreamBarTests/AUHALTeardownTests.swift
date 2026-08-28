@testable import ScreamBar
import AudioToolbox
import XCTest

final class AUHALTeardownTests: XCTestCase {
    private static let injectedFailure: OSStatus = -7_001

    func testFailedStopPreservesStartedUnitAndContextForRetry() throws {
        let operations = TeardownOperationsSpy(stopStatuses: [Self.injectedFailure, noErr])
        let playthrough = makePlaythrough(state: .started, operations: operations)

        XCTAssertEqual(playthrough.stopAndDispose(), ["stop AUHAL (-7001)"])
        XCTAssertEqual(playthrough.lifecycleState, .started)
        XCTAssertFalse(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.destroyContextCount, 0)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.isFullyDisposed)
        XCTAssertEqual(operations.stopCount, 2)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testFailedUninitializeDoesNotDoubleStopAndPreservesContext() throws {
        let operations = TeardownOperationsSpy(
            uninitializeStatuses: [Self.injectedFailure, noErr]
        )
        let playthrough = makePlaythrough(state: .started, operations: operations)

        XCTAssertEqual(
            playthrough.stopAndDispose(),
            ["uninitialize AUHAL (-7001)"]
        )
        XCTAssertEqual(playthrough.lifecycleState, .stopped)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.destroyContextCount, 0)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 2)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testFailedDisposeDoesNotRepeatSuccessfulStopOrUninitialize() throws {
        let operations = TeardownOperationsSpy(disposeStatuses: [Self.injectedFailure, noErr])
        let playthrough = makePlaythrough(state: .started, operations: operations)

        XCTAssertEqual(playthrough.stopAndDispose(), ["dispose AUHAL (-7001)"])
        XCTAssertEqual(playthrough.lifecycleState, .uninitialized)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.destroyContextCount, 0)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 2)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testCleanupIsIdempotentAfterSuccessfulDisposal() throws {
        let operations = TeardownOperationsSpy()
        let playthrough = makePlaythrough(state: .started, operations: operations)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    func testCreatedButUninitializedUnitDisposesWithoutInvalidTransitions() throws {
        let operations = TeardownOperationsSpy()
        let playthrough = makePlaythrough(state: .created, operations: operations)

        XCTAssertTrue(playthrough.stopAndDispose().isEmpty)
        XCTAssertEqual(operations.stopCount, 0)
        XCTAssertEqual(operations.uninitializeCount, 0)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.destroyContextCount, 1)
    }

    private func makePlaythrough(
        state: AUHALLifecycleState,
        operations: TeardownOperationsSpy
    ) -> AUHALPlaythrough {
        AUHALPlaythrough(
            testingAudioUnit: AudioUnit(bitPattern: 1)!,
            lifecycleState: state,
            renderContext: OpaquePointer(bitPattern: 2)!,
            teardownOperations: operations.makeOperations()
        )
    }
}

private final class TeardownOperationsSpy {
    private var stopStatuses: [OSStatus]
    private var uninitializeStatuses: [OSStatus]
    private var disposeStatuses: [OSStatus]

    private(set) var stopCount = 0
    private(set) var uninitializeCount = 0
    private(set) var disposeCount = 0
    private(set) var destroyContextCount = 0

    init(
        stopStatuses: [OSStatus] = [noErr],
        uninitializeStatuses: [OSStatus] = [noErr],
        disposeStatuses: [OSStatus] = [noErr]
    ) {
        self.stopStatuses = stopStatuses
        self.uninitializeStatuses = uninitializeStatuses
        self.disposeStatuses = disposeStatuses
    }

    func makeOperations() -> AUHALTeardownOperations {
        AUHALTeardownOperations(
            start: { _ in noErr },
            stop: { [weak self] _ in
                guard let self else { return kAudio_ParamError }
                stopCount += 1
                return nextStatus(from: &stopStatuses)
            },
            uninitialize: { [weak self] _ in
                guard let self else { return kAudio_ParamError }
                uninitializeCount += 1
                return nextStatus(from: &uninitializeStatuses)
            },
            dispose: { [weak self] _ in
                guard let self else { return kAudio_ParamError }
                disposeCount += 1
                return nextStatus(from: &disposeStatuses)
            },
            destroyRenderContext: { [weak self] _ in
                self?.destroyContextCount += 1
            }
        )
    }

    private func nextStatus(from statuses: inout [OSStatus]) -> OSStatus {
        guard !statuses.isEmpty else { return noErr }
        return statuses.removeFirst()
    }
}
