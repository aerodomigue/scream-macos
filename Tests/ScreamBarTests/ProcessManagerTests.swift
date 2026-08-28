@testable import ScreamBar
import XCTest

final class ProcessManagerTests: XCTestCase {
    func testStopAndWaitObservesOwnedProcessTermination() async throws {
        let processManager = ProcessManager()
        addTeardownBlock {
            processManager.forceTerminate()
        }
        try processManager.start(
            executablePath: "/bin/sleep",
            arguments: ["30"]
        )
        XCTAssertTrue(processManager.isRunning)

        let terminationStatus = try await processManager.stopAndWait()

        XCTAssertNotNil(terminationStatus)
        XCTAssertFalse(processManager.isRunning)
    }

    func testStopAndWaitIsIdempotentWithoutAnOwnedProcess() async throws {
        let processManager = ProcessManager()

        let terminationStatus = try await processManager.stopAndWait()

        XCTAssertNil(terminationStatus)
    }
}
