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
    }

    func testOwnerInviteRejectsNoncanonicalE2EShareLinks() {
        let rejectedLinks = [
            "https://rishi.fidexa.org/sharing/session?token=raw-token",
            "https://user@api-e2e.fidexa.org/sharing/session?token=raw-token",
            "https://user:password@api-e2e.fidexa.org/sharing/session?token=raw-token",
            "https://api-e2e.fidexa.org:443/sharing/session?token=raw-token",
            "https://api-e2e.fidexa.org/sharing/session?token=raw-token#fragment",
            "https://api-e2e.fidexa.org/sharing/session/?token=raw-token",
            "https://api-e2e.fidexa.org/sharing%2Fsession?token=raw-token",
            "https://api-e2e.fidexa.org/sharing/session?TOKEN=raw-token",
            "https://api-e2e.fidexa.org/sharing/session?to%6Ben=raw-token",
            "https://api-e2e.fidexa.org/sharing/session?token=raw-token&role=owner",
            "https://api-e2e.fidexa.org/sharing/session?token=first&token=second",
            "https://api-e2e.fidexa.org/sharing/session?token=",
        ]

        for link in rejectedLinks {
            XCTAssertNil(SharedReadingTestSupport.inviteToken(from: link), link)
        }
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
