import Foundation
import Synchronization
import Testing
@testable import rishi

@Suite("Session credential ownership — isolated storage")
struct SessionCredentialAuthorityTests {
    private func session(_ owner: String, token: String? = nil, expiry: Date? = nil) -> Session {
        Session(token: token ?? "access-\(owner)", userId: owner, email: "relay@privaterelay.appleid.com",
                issuedAt: Date(timeIntervalSince1970: 1), expiresAt: expiry)
    }

    private func install(_ owner: String, authority: SessionCredentialAuthority,
                         refresh: String? = "refresh", expiry: Date? = nil) throws -> CredentialSnapshot {
        let transition = try authority.beginTransition(expected: authority.attemptTicket())
        return try authority.install(session: session(owner, expiry: expiry), refreshToken: refresh, in: transition)
    }

    @Test("Refresh rotates only tokens/revision and never carries expired access metadata")
    func refreshMetadata() throws {
        let storage = CredentialMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let original = try install("apple.raw.sub", authority: authority, expiry: Date(timeIntervalSince1970: 2))
        let fresh = try authority.commitRefresh(accessToken: "fresh-access", refreshToken: "fresh-refresh",
                                                issuedAt: Date(timeIntervalSince1970: 100), expected: original)
        #expect(fresh.lease == original.lease)
        #expect(fresh.ticket == original.ticket)
        #expect(fresh.tokenRevision == original.tokenRevision + 1)
        #expect(fresh.session.userId == original.session.userId)
        #expect(fresh.session.email == original.session.email)
        #expect(fresh.session.issuedAt == Date(timeIntervalSince1970: 100))
        #expect(fresh.session.expiresAt == nil)
        #expect(fresh.session.token == "fresh-access")
        #expect(fresh.refreshToken == "fresh-refresh")
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try authority.commitRefresh(accessToken: "late", refreshToken: "late", issuedAt: Date(), expected: original)
        }
    }

    @Test("A to B to A and same-owner reinstall never reuse the old lease or ticket")
    func aba() throws {
        let storage = CredentialMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try install("A", authority: authority)
        let staleTicket = a.ticket
        _ = try install("B", authority: authority)
        let current = try install("A", authority: authority)
        #expect(current.lease != a.lease)
        #expect(current.ticket != a.ticket)
        let bytes = storage.bytes
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try authority.beginTransition(expected: staleTicket)
        }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try authority.commitRefresh(accessToken: "old", refreshToken: "old", issuedAt: Date(), expected: a)
        }
        #expect(storage.bytes == bytes)
        #expect(try authority.snapshot() == current)
        let reinstalled = try install("A", authority: authority)
        #expect(reinstalled.lease != current.lease)
    }

    @Test("Fencing closes ordinary requests and retains only the exact outgoing deletion context")
    func deletionContext() throws {
        let authority = SessionCredentialAuthority(persistence: CredentialMemoryPersistence())
        let a = try install("A", authority: authority)
        let transition = try authority.beginTransition(expected: a.ticket)
        guard case .loaded(let outgoing) = transition.outgoing else { Issue.record("No outgoing session"); return }
        #expect(outgoing.lease != a.lease)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot(for: .normal(a.lease)) }
        let context = CredentialRequestContext.deletion(transactionID: transition.id, outgoingLease: outgoing.lease)
        #expect(try authority.snapshot(for: context) == outgoing)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try authority.snapshot(for: .deletion(transactionID: UUID(), outgoingLease: outgoing.lease))
        }
        let restored = try authority.restoreOutgoing(in: transition)
        #expect(restored.session == a.session)
        #expect(restored.lease != outgoing.lease)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot(for: context) }
        #expect(authority.clear(in: transition) == .superseded)
    }

    @Test("Definitive rejection must still match the token revision and admission ticket")
    func rejectionCAS() throws {
        let authority = SessionCredentialAuthority(persistence: CredentialMemoryPersistence())
        let a = try install("A", authority: authority)
        let fresh = try authority.commitRefresh(accessToken: "new", refreshToken: "new", issuedAt: Date(), expected: a)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try authority.beginTransition(expected: a.ticket, rejection: a.rejectionContext)
        }
        #expect(try authority.snapshot() == fresh)
        let transition = try authority.beginTransition(expected: fresh.ticket, rejection: fresh.rejectionContext)
        #expect(authority.isCurrent(transition))
        #expect(!authority.isCurrent(fresh.lease))
    }

    @Test("No-refresh sessions cannot manufacture refresh capability")
    func noRefresh() throws {
        let authority = SessionCredentialAuthority(persistence: CredentialMemoryPersistence())
        let opaque = try install("better-auth-opaque-owner", authority: authority, refresh: nil)
        #expect(opaque.refreshToken == nil)
        #expect(throws: CredentialAuthenticationFailure.reauthenticationRequired) {
            try authority.commitRefresh(accessToken: "new", refreshToken: "manufactured", issuedAt: Date(), expected: opaque)
        }
        #expect(try authority.snapshot() == opaque)
    }

    @Test("Failed refresh preserves committed revision; failed install stays fenced until explicit restore")
    func failedWrites() throws {
        let storage = CredentialMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try install("A", authority: authority)
        let bytes = storage.bytes
        storage.failure = .update
        #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-1))) {
            try authority.commitRefresh(accessToken: "new", refreshToken: "new", issuedAt: Date(), expected: a)
        }
        #expect(try authority.snapshot() == a)
        #expect(storage.bytes == bytes)
        let transition = try authority.beginTransition(expected: a.ticket)
        #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-1))) {
            try authority.install(session: session("B"), refreshToken: nil, in: transition)
        }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot() }
        #expect(storage.bytes == bytes)
        storage.failure = nil
        let restored = try authority.restoreOutgoing(in: transition)
        #expect(restored.session == a.session)
        #expect(restored.lease != a.lease)
    }

    @Test("Failed clear remains locally fenced; retry commits tombstone and legacy cannot resurrect")
    func failedClearAndRetry() throws {
        let storage = CredentialMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try install("A", authority: authority)
        let transition = try authority.beginTransition(expected: a.ticket)
        storage.failure = .update
        #expect(authority.clear(in: transition) == .persistenceIncomplete(.securityStatus(-1)))
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot() }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.restoreOutgoing(in: transition) }
        // A memory fence is not a durable clear: a separate relaunch still reads A.
        #expect(try SessionCredentialAuthority(persistence: storage).snapshot().session.userId == "A")
        storage.failure = .legacyRemoval
        storage.legacy = .init(accessToken: "stale", refreshToken: "stale", userID: "A")
        #expect(authority.clear(in: transition) == .cleared)
        #expect(authority.clear(in: transition) == .cleared)
        #expect(authority.isCurrent(transition))
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try authority.snapshot() }
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try SessionCredentialAuthority(persistence: storage).snapshot() }
        let next = try authority.beginTransition(expected: authority.attemptTicket())
        guard case .absent = next.outgoing else { Issue.record("Successful clear retained outgoing credentials"); return }
    }

    @Test("A failed-clear retry cannot clear B, and new sign-in remains possible")
    func supersededClear() throws {
        let storage = CredentialMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try install("A", authority: authority)
        let old = try authority.beginTransition(expected: a.ticket)
        storage.failure = .update
        #expect(authority.clear(in: old) == .persistenceIncomplete(.securityStatus(-1)))
        storage.failure = nil
        let b = try install("B", authority: authority)
        #expect(authority.clear(in: old) == .superseded)
        #expect(!authority.isCurrent(old))
        #expect(try authority.snapshot() == b)
    }

    @Test("Unavailable reads do not become anonymous; fencing is still available")
    func failedRead() throws {
        let storage = CredentialMemoryPersistence()
        storage.failure = .canonicalRead
        let authority = SessionCredentialAuthority(persistence: storage)
        #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-1))) { try authority.snapshot() }
        let transition = try authority.beginTransition(expected: authority.attemptTicket())
        guard case .unavailable(.securityStatus(-1)) = transition.outgoing else { Issue.record("Read error lost"); return }
        #expect(storage.legacyReads == 0)
        storage.failure = nil
        let b = try authority.install(session: session("B"), refreshToken: nil, in: transition)
        #expect(try authority.snapshot() == b)
    }

    @Test("Matching JWT legacy pairs migrate once; mismatched refresh loses only refresh capability", arguments: [true, false])
    func legacyJWT(refreshMatches: Bool) throws {
        let access = jwt(owner: "apple.raw.sub")
        let original = session("apple.raw.sub", token: access, expiry: Date(timeIntervalSince1970: 8))
        let storage = CredentialMemoryPersistence(bytes: try JSONEncoder().encode(original),
            legacy: .init(accessToken: access, refreshToken: jwt(owner: refreshMatches ? original.userId : "other"), userID: original.userId))
        let authority = SessionCredentialAuthority(persistence: storage)
        let value = try authority.snapshot()
        #expect(value.session == original)
        #expect((value.refreshToken != nil) == refreshMatches)
        #expect(storage.removals == 1)
        #expect(storage.legacyReads == 1)
        let relaunch = try SessionCredentialAuthority(persistence: storage).snapshot()
        #expect(relaunch.session == value.session)
        #expect(relaunch.lease.installationID == value.lease.installationID)
        #expect(storage.legacyReads == 1)
    }

    @Test("Opaque flat-only and blob-only installations preserve raw identity without refresh", arguments: [true, false])
    func opaqueLegacy(flatOnly: Bool) throws {
        let original = session("opaque.better-auth.owner", token: "opaque-access")
        let storage = CredentialMemoryPersistence(bytes: flatOnly ? nil : try JSONEncoder().encode(original),
            legacy: flatOnly ? .init(accessToken: original.token, refreshToken: jwt(owner: original.userId), userID: original.userId)
                            : .init(accessToken: nil, refreshToken: nil, userID: nil))
        let value = try SessionCredentialAuthority(persistence: storage).snapshot()
        #expect(value.session.token == original.token)
        #expect(value.session.userId == original.userId)
        #expect(value.refreshToken == nil)
        if !flatOnly { #expect(value.session.email == original.email) }
    }

    @Test("Contradictory, partial, corrupt and future records fail without fallback")
    func invalidMigration() throws {
        let original = session("A")
        let mismatch = CredentialMemoryPersistence(bytes: try JSONEncoder().encode(original),
            legacy: .init(accessToken: original.token, refreshToken: nil, userID: "B"))
        #expect(throws: CredentialAuthenticationFailure.unavailable(.inconsistentLegacy)) {
            try SessionCredentialAuthority(persistence: mismatch).snapshot()
        }
        #expect(mismatch.removals == 0)
        let partial = CredentialMemoryPersistence(legacy: .init(accessToken: "access", refreshToken: nil, userID: nil))
        #expect(throws: CredentialAuthenticationFailure.unavailable(.inconsistentLegacy)) {
            try SessionCredentialAuthority(persistence: partial).snapshot()
        }
        let corrupt = CredentialMemoryPersistence(bytes: Data("{broken".utf8), legacy: .init(accessToken: "access", refreshToken: nil, userID: "A"))
        #expect(throws: CredentialAuthenticationFailure.unavailable(.invalidRecord)) {
            try SessionCredentialAuthority(persistence: corrupt).snapshot()
        }
        #expect(corrupt.legacyReads == 0)
        let future = CanonicalCredentialRecord(version: 99, installationID: UUID(), tokenRevision: 0, session: original, refreshToken: nil)
        let unknown = CredentialMemoryPersistence(bytes: try JSONEncoder().encode(future))
        #expect(throws: CredentialAuthenticationFailure.unavailable(.unsupportedVersion)) {
            try SessionCredentialAuthority(persistence: unknown).snapshot()
        }
    }

    @Test("Migration/add failures do not publish or remove legacy; retry can recover")
    func failedMigrationAndAdd() throws {
        let original = session("A")
        let storage = CredentialMemoryPersistence(legacy: .init(accessToken: original.token, refreshToken: nil, userID: original.userId))
        storage.failure = .add
        let authority = SessionCredentialAuthority(persistence: storage)
        #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-1))) { try authority.snapshot() }
        #expect(storage.bytes == nil)
        #expect(storage.removals == 0)
        storage.failure = nil
        #expect(try authority.snapshot().session.userId == "A")
        let inaccessible = CredentialMemoryPersistence()
        inaccessible.failure = .legacyRead
        #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-1))) {
            try SessionCredentialAuthority(persistence: inaccessible).snapshot()
        }
    }

    @Test("Concurrent refresh completions admit exactly one original revision")
    func concurrentRefreshCAS() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialMemoryPersistence())
        let a = try install("A", authority: authority)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                group.addTask {
                    do { _ = try authority.commitRefresh(accessToken: "new-\(index)", refreshToken: "new-\(index)", issuedAt: Date(), expected: a); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(try authority.snapshot().tokenRevision == a.tokenRevision + 1)
    }

    @Test("Caller MainActor mutation is atomic with admission, including cleared-owner publication")
    @MainActor
    func guardedMutation() throws {
        let authority = SessionCredentialAuthority(persistence: CredentialMemoryPersistence())
        let a = try install("A", authority: authority)
        var published = 0
        #expect(authority.performIfCurrent(a.lease) { published += 1 })
        let transition = try authority.beginTransition(expected: a.ticket)
        #expect(!authority.performIfCurrent(a.lease) { published += 1 })
        #expect(authority.clear(in: transition) == .cleared)
        #expect(authority.performIfCurrent(transition) { published += 1 })
        _ = try install("B", authority: authority)
        #expect(!authority.performIfCurrent(transition) { published += 1 })
        #expect(published == 2)
    }
}

private func jwt(owner: String) -> String {
    let data = try! JSONEncoder().encode(["userId": owner])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private final class CredentialMemoryPersistence: SessionCredentialPersistence {
    enum Failure: Sendable { case canonicalRead, legacyRead, add, update, legacyRemoval }
    private struct State {
        var bytes: Data?
        var legacy: LegacyCredentials
        var failure: Failure?
        var legacyReads = 0
        var removals = 0
    }
    private let state: Mutex<State>
    init(bytes: Data? = nil, legacy: LegacyCredentials = .init(accessToken: nil, refreshToken: nil, userID: nil)) {
        state = Mutex(State(bytes: bytes, legacy: legacy))
    }
    var bytes: Data? { state.withLock { $0.bytes } }
    var legacyReads: Int { state.withLock { $0.legacyReads } }
    var removals: Int { state.withLock { $0.removals } }
    var failure: Failure? { get { state.withLock { $0.failure } } set { state.withLock { $0.failure = newValue } } }
    var legacy: LegacyCredentials { get { state.withLock { $0.legacy } } set { state.withLock { $0.legacy = newValue } } }
    func readCanonical() throws -> Data? {
        try state.withLock { state in
            if state.failure == .canonicalRead { throw CredentialStorageFailure.securityStatus(-1) }
            return state.bytes
        }
    }
    func writeCanonical(_ data: Data) throws {
        try state.withLock { state in
            if state.failure == (state.bytes == nil ? .add : .update) { throw CredentialStorageFailure.securityStatus(-1) }
            state.bytes = data
        }
    }
    func readLegacy() throws -> LegacyCredentials {
        try state.withLock { state in
            state.legacyReads += 1
            if state.failure == .legacyRead { throw CredentialStorageFailure.securityStatus(-1) }
            return state.legacy
        }
    }
    func removeLegacy() throws {
        try state.withLock { state in
            if state.failure == .legacyRemoval { throw CredentialStorageFailure.securityStatus(-1) }
            state.removals += 1
            state.legacy = .init(accessToken: nil, refreshToken: nil, userID: nil)
        }
    }
}
