import Foundation
import Testing
@testable import rishi

@Suite("Account deletion coordinator")
struct AccountDeletionCoordinatorTests {
    @Test("Apple authorization code is serialized alongside the identity token")
    func authorizationCodeEncoding() throws {
        let body = JWTEndPoint.BodyType(
            identityToken: "identity-jwt",
            authorizationCode: Data("apple-code".utf8).base64EncodedString()
        )
        let json = try JSONEncoder().encode(body)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: String])
        #expect(object["identityToken"] == "identity-jwt")
        #expect(object["authorizationCode"] == Data("apple-code".utf8).base64EncodedString())
    }

    @Test("server failure does not purge local data or sign out")
    func serverFailurePreservesSession() async {
        let state = TestState()
        let coordinator = AccountDeletionCoordinator(
            deleteServer: { throw TestError.failed },
            purgeLocal: { state.purged = true },
            signOut: { state.signedOut = true }
        )

        await #expect(throws: TestError.failed) {
            try await coordinator.run()
        }
        #expect(!state.purged)
        #expect(!state.signedOut)
    }

    @Test("successful server deletion purges local data before signing out")
    func successOrdersCleanupBeforeSignOut() async throws {
        let state = TestState()
        let coordinator = AccountDeletionCoordinator(
            deleteServer: { state.events.append("server") },
            purgeLocal: { state.events.append("purge") },
            signOut: { state.events.append("signout") }
        )

        try await coordinator.run()
        #expect(state.events == ["server", "purge", "signout"])
    }

    @Test("local purge failure signs out and still reports the cleanup error")
    func localFailureSignsOut() async {
        let state = TestState()
        let coordinator = AccountDeletionCoordinator(
            deleteServer: {},
            purgeLocal: { throw TestError.failed },
            signOut: { state.signedOut = true }
        )

        await #expect(throws: TestError.failed) {
            try await coordinator.run()
        }
        #expect(state.signedOut)
    }

    private final class TestState: @unchecked Sendable {
        var purged = false
        var signedOut = false
        var events: [String] = []
    }

    private enum TestError: Error, Equatable {
        case failed
    }
}
