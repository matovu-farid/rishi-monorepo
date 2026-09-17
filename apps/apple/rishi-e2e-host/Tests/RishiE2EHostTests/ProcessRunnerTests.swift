import Foundation
import XCTest
@testable import RishiE2EHost

final class ProcessRunnerTests: XCTestCase {
    func testFoundationRunnerCapturesOutputAndExitStatus() async throws {
        let handle = try FoundationProcessRunner().start(ProcessRequest(
            executablePath: "/usr/bin/printf",
            arguments: ["host-output"]
        ))

        let result = try await handle.wait()

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdout, "host-output")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testCancelledProcessCleansUpOwnedDescendants() async throws {
        let handle = try FoundationProcessRunner().start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 30"]
        ))

        handle.cancel()
        _ = try await handle.wait()
    }
}
