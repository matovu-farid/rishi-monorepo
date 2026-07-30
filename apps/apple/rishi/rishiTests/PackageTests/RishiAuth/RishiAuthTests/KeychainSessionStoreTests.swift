@testable import rishi
import Foundation
import Testing



@Suite("KeychainSessionStore — round-trip + delete + persistence")
struct KeychainSessionStoreTests {

    // MARK: - Helpers

    private func makeSession(
        token: String = "tok-1",
        email: String? = "u@example.com"
    ) -> Session {
        // Plan 15-02: Session.userId is `String` (Better Auth `user.id`).
        // Tests use a stable literal so equality assertions are deterministic.
        Session(
            token: token,
            userId: "001234.abcdef0123456789.1234",
            email: email,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
    }

    // MARK: - Round trip

    @Test func saveThenLoadReturnsEqualSession() async throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainSessionStore(backend: backend)
        let original = makeSession(token: "round-trip-tok")

        try await store.save(original)
        let loaded = try await store.load()

        #expect(loaded == original)
    }

    // MARK: - Overwrite

    @Test func savingTwiceOverwritesAndDoesNotDuplicate() async throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainSessionStore(backend: backend)

        try await store.save(makeSession(token: "first"))
        try await store.save(makeSession(token: "second"))

        let loaded = try await store.load()
        #expect(loaded?.token == "second")
        let count = backend.snapshotItemCount()
        #expect(count == 1, "Expected exactly one keychain item; got \(count)")
    }

    // MARK: - Delete

    @Test func deleteRemovesTheItem() async throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainSessionStore(backend: backend)

        try await store.save(makeSession())
        try await store.delete()

        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    // MARK: - Empty store

    @Test func loadFromEmptyStoreReturnsNil() async throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainSessionStore(backend: backend)

        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    // MARK: - Persistence across instances (proves data lives in backend, not store)

    @Test func sessionVisibleToFreshStoreSharingSameBackend() async throws {
        let backend = InMemoryKeychainBackend()
        let storeA = KeychainSessionStore(backend: backend)
        let original = makeSession(token: "persisted")
        try await storeA.save(original)

        // Simulate process relaunch: a new KeychainSessionStore reading from the same backend.
        let storeB = KeychainSessionStore(backend: backend)
        let loaded = try await storeB.load()
        #expect(loaded == original)
    }

    // MARK: - PITFALLS.md Pitfall 10 — private-relay email passes through unchanged

    @Test func privateRelayEmailRoundTripsExactly() async throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainSessionStore(backend: backend)
        let relayEmail = "abc123@privaterelay.appleid.com"
        let session = makeSession(token: "relay-tok", email: relayEmail)

        try await store.save(session)
        let loaded = try await store.load()
        #expect(loaded?.email == relayEmail)
    }

    // MARK: - Constants used by the system backend are stable

    @Test func storeUsesStableServiceAndAccountConstants() {
        #expect(KeychainSessionStore.service == "org.fidexa.rishi.session")
        #expect(KeychainSessionStore.account == "current")
    }
}
