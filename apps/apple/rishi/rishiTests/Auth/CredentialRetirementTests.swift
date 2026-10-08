import Foundation
import Synchronization
import Testing
@testable import rishi

/// Fixture-only storage shared by the actual engine reservation regressions.
final class CredentialStagingMemoryPersistence: SessionCredentialPersistence {
    private struct State { var data: Data?; var failWrites = false }
    private let state = Mutex(State())
    var failsWrites: Bool {
        get { state.withLock { $0.failWrites } }
        set { state.withLock { $0.failWrites = newValue } }
    }
    var bytes: Data? { state.withLock { $0.data } }
    func readCanonical() -> Data? { bytes }
    func readLegacy() -> LegacyCredentials { .init(accessToken: nil, refreshToken: nil, userID: nil) }
    func removeLegacy() {}
    func writeCanonical(_ data: Data) throws {
        try state.withLock {
            guard !$0.failWrites else { throw CredentialStorageFailure.securityStatus(-50) }
            $0.data = data
        }
    }
}

func installStagingCredentials(_ rawID: String, authority: SessionCredentialAuthority) throws -> CredentialSnapshot {
    try authority.install(
        session: Session(token: "fixture-\(rawID)", userId: rawID, email: nil),
        refreshToken: "fixture-refresh-\(rawID)",
        in: authority.beginTransition(expected: authority.attemptTicket())
    )
}

actor CredentialStagingGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func markEntered() {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
    }
    func suspend() async {
        markEntered()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { release = continuation }
            }
        } onCancel: {
            Task { await self.resume() }
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { entryWaiters.append(continuation) }
            }
        } onCancel: {
            Task { await self.cancelEntryWaiters() }
        }
    }
    private func cancelEntryWaiters() {
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
    }
    func resume() { release?.resume(); release = nil }
}

@MainActor
@Suite("Credential retirement — injected owners only", .serialized, .timeLimit(.minutes(1)))
struct CredentialRetirementTests {
    private func dependencies(
        _ authority: SessionCredentialAuthority,
        userID: UUID?,
        cleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void = { _ in }
    ) -> AppDependencies {
        AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(userID),
                        accountGeneration: 17, persistAccountGeneration: { _ in }, credentialCleanup: cleanup)
    }

    private func identityDependencies(
        _ authority: SessionCredentialAuthority, userID: UUID?,
        cleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void = { _ in }
    ) throws -> AppDependencies {
        try CredentialIdentityFixture(authority: authority, ownerID: userID, cleanup: cleanup).dependencies
    }

    @Test("stale sign-in admission leaves B's credentials, generation and identity unchanged")
    func staleTicket() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let deps = try identityDependencies(authority, userID: DerivedUserID.from("A"))
        let transition = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        let b = try await deps.installCredentialSession(Session(token: "B-token", userId: "B", email: nil), refreshToken: nil, in: transition)
        let generation = deps.accountGeneration
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        }
        #expect(try authority.snapshot() == b)
        #expect(deps.accountGeneration == generation)
        #expect(deps.cachedUserId == DerivedUserID.from("B"))
        #expect(deps.pendingAccountChange == nil)
    }

    @Test("cleanup reservation rejects admission before fencing and retains outgoing DELETE")
    func preflightBeforeFence() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let deps = dependencies(authority, userID: DerivedUserID.from("A"))
        let tx = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        await tx.drain.value
        #expect(deps.beginAccountCleanup(tx))
        let ticket = authority.attemptTicket()
        let generation = deps.accountGeneration
        #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try deps.beginAccountChange(expectedCredentialTicket: ticket)
        }
        #expect(authority.attemptTicket() == ticket)
        #expect(deps.accountGeneration == generation)
        #expect(deps.cachedUserId == DerivedUserID.from("A"))
        #expect(deps.pendingAccountChange === tx)
        let admission = try #require(tx.deletionAdmission)
        let transition = try #require(tx.credentialTransition)
        guard case .loaded(let outgoing) = transition.outgoing else { Issue.record("Missing outgoing snapshot"); return }
        #expect(try authority.snapshot(for: admission.requestContext) == outgoing)
        #expect(outgoing.lease == admission.outgoingLease)
        #expect(outgoing.lease.installationID == a.lease.installationID)
        #expect(outgoing.lease.rawUserID == a.lease.rawUserID)
        #expect(outgoing.lease.epoch == a.lease.epoch &+ 1)
        #expect(outgoing.tokenRevision == a.tokenRevision)
        #expect(outgoing.session == a.session)
        #expect(outgoing.refreshToken == a.refreshToken)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try authority.snapshot(for: .normal(a.lease))
        }
        deps.endAccountCleanup(tx)
        let newer = try deps.beginAccountChange(expectedCredentialTicket: ticket)
        await newer.drain.value
        #expect(deps.beginAccountCleanup(newer))
        deps.endAccountCleanup(tx)
        #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        }
        deps.endAccountCleanup(newer)
    }

    @Test("B can supersede A before cleanup claims ownership, and A performs no cleanup")
    func supersededBeforeClaim() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let calls = Mutex(0)
        let deps = try identityDependencies(authority, userID: DerivedUserID.from("A")) { _ in calls.withLock { $0 += 1 } }
        let tx = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        let retired = try #require(deps.retireCredentialAccount(tx))
        let bTx = try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        let b = try await deps.installCredentialSession(Session(token: "B-token", userId: "B", email: nil), refreshToken: nil, in: bTx)
        await retired.value
        #expect(calls.withLock { $0 } == 0)
        #expect(try authority.snapshot() == b)
        #expect(deps.cachedUserId == DerivedUserID.from("B"))
    }

    @Test("definitive rejection admits without joining, coalesces, and reserves its completion")
    func nonjoiningRetirement() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let deps = dependencies(authority, userID: DerivedUserID.from("A")) { _ in await gate.suspend() }
        let admission = deps.admitCredentialRejection(.invalidRefreshToken, context: a.rejectionContext)
        guard case .admitted(let id) = admission else { Issue.record("Expected admission"); return }
        guard case .duplicate(let duplicate) = deps.admitCredentialRejection(.invalidRefreshToken, context: a.rejectionContext) else {
            Issue.record("Expected duplicate ownership"); return
        }
        #expect(id == duplicate)
        let tx = try #require(deps.pendingAccountChange)
        let task = try #require(deps.retireCredentialAccount(tx))
        await gate.waitUntilEntered()
        #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        }
        await gate.resume()
        await task.value
        #expect(deps.cachedUserId == nil)
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try authority.snapshot() }
    }

    @Test("failed tombstone stays fenced, retry is durable, and completed cleanup releases reservation")
    func durableFailureAndRetry() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let deps = dependencies(authority, userID: DerivedUserID.from("A"))
        let original = storage.bytes
        storage.failsWrites = true
        let tx = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        let retired = try #require(deps.retireCredentialAccount(tx))
        await retired.value
        #expect(storage.bytes == original)
        #expect(deps.cachedUserId == DerivedUserID.from("A"))
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot() }
        guard case .failure(let error)? = deps.credentialRetirementResult else { Issue.record("Missing durable failure"); return }
        #expect(error as? CredentialAuthenticationFailure == .unavailable(.securityStatus(-50)))
        storage.failsWrites = false
        let retried = try #require(deps.retryCredentialRetirement())
        await retried.value
        #expect(deps.cachedUserId == nil)
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try authority.snapshot() }
        _ = try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
    }

    @Test("injected instances reject every unscoped identity route and never bootstrap")
    func noLegacyFallback() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let deps = dependencies(authority, userID: DerivedUserID.from("A"))
        #expect(await deps.replaceUserId(DerivedUserID.from("B")) == false)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try deps.beginAccountChange() }
        await deps.bootstrap()
        #expect(deps.services == nil)
        #expect(try authority.snapshot() == a)
    }
}

@Suite("Credential consent — actual actor mutations", .serialized)
struct CredentialConsentOwnershipTests {
    @Test("defaults writes use derived UUID keys and reject stale bind, grant, revoke and clear")
    func defaultsAdmission() async throws {
        let name = "credential-consent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("opaque-A", authority: authority)
        let store = UserDefaultsDataUseConsentStore(defaults: defaults, credentialAuthority: authority)
        #expect(await store.bind(to: a.lease))
        #expect(await store.grant(for: a.lease))
        let key = UserDefaultsDataUseConsentStore.key(for: DerivedUserID.from("opaque-A").uuidString)
        let bytes = try #require(defaults.data(forKey: key))
        #expect(defaults.data(forKey: UserDefaultsDataUseConsentStore.key(for: "opaque-A")) == nil)
        let old = try authority.beginTransition(expected: a.ticket)
        let b = try authority.install(session: Session(token: "B", userId: "B", email: nil), refreshToken: nil, in: old)
        #expect(await store.bind(to: b.lease))
        #expect(await store.grant(for: b.lease))
        #expect(await store.bind(to: a.lease) == false)
        #expect(await store.grant(for: a.lease) == false)
        #expect(await store.revoke(for: a.lease) == false)
        #expect(await store.clear(for: old) == false)
        #expect(defaults.data(forKey: key) == bytes)
        #expect(await store.record(for: b.lease) != nil)
        await store.setCurrentUser("opaque-A")
        await store.revoke(for: DerivedUserID.from("B").uuidString)
        await store.clearCurrentUser()
        #expect(await store.record(for: b.lease) != nil)
    }

    @Test("A to B to A reinstall rejects queued same-ID effects and provider never changes context")
    func abaAndProvider() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("opaque-A", authority: authority)
        let store = InMemoryDataUseConsentStore(credentialAuthority: authority)
        #expect(await store.bind(to: a.lease))
        let gate = CredentialStagingGate()
        let delayed = Task {
            await gate.suspend()
            let bound = await store.bind(to: a.lease)
            let granted = await store.grant(for: a.lease)
            return (bound, granted)
        }
        await gate.waitUntilEntered()
        _ = try installStagingCredentials("B", authority: authority)
        let newer = try installStagingCredentials("opaque-A", authority: authority)
        #expect(await store.bind(to: newer.lease))
        #expect(await store.grant(for: newer.lease))
        await gate.resume()
        let delayedResults = await delayed.value
        #expect(delayedResults.0 == false && delayedResults.1 == false)
        #expect(await store.revoke(for: a.lease) == false)
        #expect(await store.bind(to: a.lease) == false)
        #expect(await store.record(for: newer.lease) != nil)
        let provider = AccountDataUseConsentProvider(store: store, credentialAuthority: authority)
        #expect(await provider.hasCurrentDataUseConsent())
        let tx = try authority.beginTransition(expected: newer.ticket)
        #expect(await provider.hasCurrentDataUseConsent() == false)
        #expect(await store.clear(for: tx))
        #expect(await store.record(for: newer.lease) == nil)
    }
}
