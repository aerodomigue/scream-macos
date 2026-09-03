@testable import ScreamBar
import XCTest

@MainActor
final class USBTriggerCommandRunnerTests: XCTestCase {
    func testEmptyCommandSucceedsWithoutLaunchingBash() async throws {
        let runner = USBTriggerCommandRunner()

        let output = try await runner.run("   \n")

        XCTAssertTrue(output.isEmpty)
    }

    func testSuccessfulBashCommandCompletes() async throws {
        let runner = USBTriggerCommandRunner()

        let output = try await runner.run("printf 'ready\\n'; printf 'warning\\n' >&2")

        XCTAssertTrue(output.contains("stdout:\nready"))
        XCTAssertTrue(output.contains("stderr:\nwarning"))
    }

    func testNonZeroBashExitIsReported() async {
        let runner = USBTriggerCommandRunner()

        do {
            _ = try await runner.run("exit 17")
            XCTFail("Expected the command failure to be reported")
        } catch let error as USBTriggerCommandError {
            guard case .nonZeroExitStatus(let status, _) = error else {
                return XCTFail("Expected a non-zero exit status")
            }
            XCTAssertEqual(status, 17)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
