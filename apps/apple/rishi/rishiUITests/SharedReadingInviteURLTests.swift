import XCTest

final class SharedReadingInviteURLTests: XCTestCase {
    @MainActor
    func testExtractsDecodedTokenFromSupportedSessionLink() {
        XCTAssertEqual(
            SharedReadingTestSupport.inviteToken(from: "rishi://sharing/session?token=abc%2F123"),
            "abc/123"
        )
        XCTAssertEqual(
            SharedReadingTestSupport.inviteToken(from: "https://rishi.fidexa.org/sharing/session?token=abc%2F123"),
            "abc/123"
        )
    }

    @MainActor
    func testRejectsUnsupportedOrMalformedLinks() {
        XCTAssertNil(SharedReadingTestSupport.inviteToken(from: "rishi://sharing/join?token=abc"))
        XCTAssertNil(SharedReadingTestSupport.inviteToken(from: "https://example.com/session?token=abc"))
        XCTAssertNil(SharedReadingTestSupport.inviteToken(from: "rishi://sharing/session"))
    }
}
