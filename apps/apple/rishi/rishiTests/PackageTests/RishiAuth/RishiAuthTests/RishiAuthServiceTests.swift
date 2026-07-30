@testable import rishi
import Foundation
import Testing

@Suite("Current authentication session services", .serialized)
struct RishiAuthServiceTests {
    private static func makeSession(token: String = "tok") -> Session {
        Session(
            token: token,
            userId: "001234.abcdef0123456789.1234",
            email: "u@example.com",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
    }

    @Test("keychain session survives a fresh store instance")
    func sessionPersistsAcrossStoreInstances() async throws {
        let backend = InMemoryKeychainBackend()
        let first = KeychainSessionStore(backend: backend)
        try await first.save(Self.makeSession())

        let second = KeychainSessionStore(backend: backend)
        #expect(try await second.load() == Self.makeSession())
    }

    @Test("token provider reads the current keychain session")
    func tokenProviderReadsCurrentSession() async throws {
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let provider = RishiAuthTokenProvider(keychain: keychain)

        #expect(await provider.token() == nil)
        try await keychain.save(Self.makeSession(token: "live"))
        #expect(await provider.token() == "live")
        try await keychain.delete()
        #expect(await provider.token() == nil)
    }
}
