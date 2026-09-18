import XCTest
@testable import RishiE2EHost

final class SharedReadingLiveEndToEndTests: XCTestCase {
    func testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress() async throws {
        guard ProcessInfo.processInfo.environment["RISHI_E2E_RUN_LIVE"] == "1" else {
            throw XCTSkip("Set RISHI_E2E_RUN_LIVE=1 only for an explicitly configured local live run.")
        }

        XCTFail("SharedReadingLiveRun has not been wired yet")
    }
}
