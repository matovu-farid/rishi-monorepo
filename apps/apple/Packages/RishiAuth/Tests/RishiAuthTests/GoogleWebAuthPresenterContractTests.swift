import Foundation
import Testing
import RishiCore
@testable import RishiAuth

/// Compile-time contract for ``GoogleWebAuthPresenter``: anything Sendable that
/// exposes `presentWebAuth(url:callbackScheme:)` must satisfy the protocol.
/// Mirrors the SiwaPresenter-style protocol seam (plan 03-03 wave 2 sibling).
@Suite("GoogleWebAuthPresenter — protocol contract")
struct GoogleWebAuthPresenterContractTests {

    /// Minimal stub that conforms to the protocol — proves the public surface
    /// compiles. The real coverage of behavioural paths lives in
    /// ``GoogleOAuthFlowTests`` (Task 3).
    struct StubPresenter: GoogleWebAuthPresenter {
        let stubURL: URL
        func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
            stubURL
        }
    }

    @Test func stubPresenterReturnsConfiguredURL() async throws {
        let expected = URL(string: "rishi://auth/callback?token=t-1")!
        let stub = StubPresenter(stubURL: expected)
        let returned = try await stub.presentWebAuth(
            url: URL(string: "https://api.fidexa.org/desktop/start?provider=google&device=ios")!,
            callbackScheme: "rishi"
        )
        #expect(returned == expected)
    }
}
