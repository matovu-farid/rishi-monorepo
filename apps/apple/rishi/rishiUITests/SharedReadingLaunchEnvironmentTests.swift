import XCTest

final class SharedReadingLaunchEnvironmentTests: XCTestCase {
    func testMissingEndpointPreventsLaunchCallback() {
        var launchReached = false

        XCTAssertThrowsError(try SharedReadingTestSupport.launchWithRequiredEndpoints(
            from: ["RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org"],
            launch: { launchReached = true }
        ))
        XCTAssertFalse(launchReached)
    }

    func testInitialLaunchForwardsExactAPIAndWebSocketOrigins() throws {
        var launchReached = false
        let environment = try SharedReadingTestSupport.launchWithRequiredEndpoints(
            from: [
                "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
                "RISHI_E2E_SHARING_WS_URL": "wss://sharing-e2e.fidexa.org",
            ],
            launch: { launchReached = true }
        )

        XCTAssertTrue(launchReached)
        XCTAssertEqual(environment["RISHI_E2E_API_BASE_URL"], "https://api-e2e.fidexa.org")
        XCTAssertEqual(environment["RISHI_E2E_SHARING_WS_URL"], "wss://sharing-e2e.fidexa.org")
    }

    func testOwnerInviteAcceptsOnlyTheExactE2EAPIOriginAndRelaysRawToken() {
        XCTAssertEqual(
            SharedReadingTestSupport.inviteToken(from: "https://api-e2e.fidexa.org/sharing/session?token=raw-token"),
            "raw-token"
        )
        XCTAssertNil(SharedReadingTestSupport.inviteToken(from: "https://rishi.fidexa.org/sharing/session?token=raw-token"))
        XCTAssertNil(SharedReadingTestSupport.inviteToken(from: "https://api-e2e.fidexa.org/sharing/session?token="))
    }

    func testParticipantRestartAlsoRequiresTheExactEndpoints() {
        var launchReached = false

        XCTAssertThrowsError(try SharedReadingTestSupport.launchWithRequiredEndpoints(
            from: ["RISHI_E2E_SHARING_WS_URL": "wss://sharing-e2e.fidexa.org"],
            launch: { launchReached = true }
        ))
        XCTAssertFalse(launchReached)
    }
}
