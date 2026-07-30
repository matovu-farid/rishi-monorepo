@testable import rishi
import Foundation
import Testing




@Suite("RishiAuthTokenProvider — keychain passthrough")
struct RishiAuthTokenProviderTests {

    private static func makeSession(token: String) -> Session {
        // Plan 15-02: Session.userId is `String` (Better Auth `user.id`).
        Session(
            token: token,
            userId: "001234.abcdef0123456789.1234",
            email: nil,
            issuedAt: Date(),
            expiresAt: nil
        )
    }

    @Test func tokenIsNilWhenKeychainEmpty() async throws {
        let keychain = KeychainSessionStore(backend: InMemoryKeychainBackend())
        let provider = RishiAuthTokenProvider(keychain: keychain)
        let token = await provider.token()
        #expect(token == nil)
    }

    @Test func tokenReturnsCurrentSessionToken() async throws {
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        try await keychain.save(Self.makeSession(token: "live-tok"))

        let provider = RishiAuthTokenProvider(keychain: keychain)
        let token = await provider.token()
        #expect(token == "live-tok")
    }

    @Test func tokenReflectsLatestSessionAfterRotation() async throws {
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let provider = RishiAuthTokenProvider(keychain: keychain)

        try await keychain.save(Self.makeSession(token: "tok-1"))
        #expect(await provider.token() == "tok-1")

        // Simulate token rotation — provider must NOT cache.
        try await keychain.save(Self.makeSession(token: "tok-2"))
        #expect(await provider.token() == "tok-2")

        try await keychain.delete()
        #expect(await provider.token() == nil)
    }
}
