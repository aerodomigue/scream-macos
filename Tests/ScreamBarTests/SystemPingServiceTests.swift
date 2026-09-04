@testable import ScreamBar
import XCTest

final class SystemPingServiceTests: XCTestCase {
    func testSystemPingRecognizesIPv4Loopback() async throws {
        let isReachable = try await SystemPingService().ping(
            host: IPv4Address("127.0.0.1")
        )

        XCTAssertTrue(isReachable)
    }
}
