import Foundation
import SwiftData
import Synchronization
import Testing
@testable import rishi

actor CredentialIdentityIndex: RishiSearchIndexingClient {
    private var gate: CredentialStagingGate?
    private(set) var clears = 0
    init(gate: CredentialStagingGate? = nil) { self.gate = gate }
    func deleteAll() async throws {
        clears += 1
        let captured = gate; gate = nil
        await captured?.suspend()
        try Task.checkCancellation()
    }
    func delete(domainIdentifiers: [String]) async throws {}
    func index(_ descriptors: [RishiSpotlightDescriptor]) async throws {}
}

@MainActor
struct CredentialIdentityFixture {
    let dependencies: AppDependencies
    let mutations: BookScopedMutationStore
    let lifecycle: BookImportLifecycle
    let index: CredentialIdentityIndex
    let box: UserIdBox

    init(authority: SessionCredentialAuthority, ownerID: UUID? = nil,
         gate: CredentialStagingGate? = nil,
         cleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void = { _ in }) throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let highlights = SwiftDataHighlightStore(dbStore: db)
        let conversations = SwiftDataConversationStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let generations = Mutex<UInt64>(17)
        let identity = UserIdBox(ownerID)
        let sources = BookSourceRegistry(persistence: persistence,
            currentGeneration: { generations.withLock { $0 } },
            currentOwnerID: { await identity.value }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: sources,
            currentAccountGeneration: { generations.withLock { $0 } })
        let materialization = BookMaterializationCoordinator(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            lifecycle: lifecycle, sourceRegistry: sources, persistence: persistence,
            bookStore: books, currentGeneration: { generations.withLock { $0 } })
        let index = CredentialIdentityIndex(gate: gate)
        let spotlight = RishiSpotlightCoordinator(bookStore: books, highlightStore: highlights,
            conversationStore: conversations, currentUserID: { await identity.value }, indexingClient: index)
        let mutations = BookScopedMutationStore(dbStore: db)
        dependencies = AppDependencies(credentialAuthority: authority, userIdBox: identity,
            accountGeneration: 17, persistAccountGeneration: { value in generations.withLock { $0 = value } },
            credentialCleanup: cleanup, identityResources: CredentialIdentityResources(
                spotlight: spotlight, materialization: materialization, lifecycle: lifecycle, mutations: mutations))
        self.mutations = mutations; self.lifecycle = lifecycle; self.index = index; box = identity
    }

    func assertAllowed(_ permit: AccountMutationPermit) async throws {
        #expect(try await mutations.withAccountWrite(permit: permit) { _ in true })
    }
    func assertDenied(_ permit: AccountMutationPermit) async {
        do {
            _ = try await mutations.withAccountWrite(permit: permit) { _ in true }
            Issue.record("Closed account mutation permit unexpectedly admitted")
        } catch {
            #expect(error as? BookScopedMutationError == .unauthorized)
        }
    }
}

@MainActor
@Suite("Credential identity activation — actual isolated resources", .serialized, .timeLimit(.minutes(1)))
struct CredentialIdentityActivationTests {
    @Test("cleanup-only construction refuses bare identity publication")
    func requiresResources() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(DerivedUserID.from("A")),
            accountGeneration: 17, persistAccountGeneration: { _ in }, credentialCleanup: { _ in })
        let tx = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        let bytes = storage.bytes
        do {
            _ = try await deps.installCredentialSession(Session(token: "B", userId: "B", email: nil), refreshToken: nil, in: tx)
            Issue.record("Missing real identity resources accepted")
        } catch { #expect(error is CredentialIdentityActivationError) }
        #expect(storage.bytes == bytes)
        #expect(deps.pendingAccountChange === tx)
        #expect(deps.cachedUserId == DerivedUserID.from("A"))
        #expect(deps.beginAccountCleanup(tx)); deps.endAccountCleanup(tx)
    }

    @Test("install drains A and authorizes B before committing credentials and identity")
    func installActualResources() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let fixture = try CredentialIdentityFixture(authority: authority, ownerID: DerivedUserID.from("A"))
        let outgoing = AccountMutationPermit(ownerID: DerivedUserID.from("A"), accountGeneration: 17)
        try await fixture.mutations.activate(outgoing)
        let tx = try fixture.dependencies.beginAccountChange(expectedCredentialTicket: a.ticket)
        let b = try await fixture.dependencies.installCredentialSession(
            Session(token: "B", userId: "B", email: nil), refreshToken: nil, in: tx)
        let current = AccountMutationPermit(ownerID: DerivedUserID.from("B"), accountGeneration: tx.expectedAccountGeneration)
        try await fixture.assertAllowed(current)
        await fixture.assertDenied(outgoing)
        #expect(!fixture.lifecycle.admits(ownerID: outgoing.ownerID, generation: outgoing.accountGeneration))
        #expect(fixture.lifecycle.admits(ownerID: current.ownerID, generation: current.accountGeneration))
        #expect(await fixture.index.clears == 1)
        #expect(try authority.snapshot() == b)
        #expect(fixture.dependencies.cachedUserId == current.ownerID)
        #expect(fixture.dependencies.activeAccountIdentity == LibraryAccountIdentity(userID: current.ownerID, generation: current.accountGeneration))
        #expect(fixture.dependencies.pendingAccountChange == nil)
    }

    @Test("cold restore retains the installed credential lease, ticket and exact bytes")
    func restoreWithoutReinstall() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let bytes = storage.bytes
        let fixture = try CredentialIdentityFixture(authority: authority)
        try await fixture.dependencies.restoreCredentialIdentity(a)
        #expect(try authority.snapshot() == a)
        #expect(storage.bytes == bytes)
        #expect(fixture.dependencies.accountGeneration == 17)
        #expect(fixture.dependencies.cachedUserId == DerivedUserID.from("A"))
        #expect(await fixture.index.clears == 1)
        try await fixture.assertAllowed(AccountMutationPermit(ownerID: DerivedUserID.from("A"), accountGeneration: 17))
    }

    @Test("real Spotlight activation owns the same reservation as transition preflight")
    func restoreReservationBeforeFence() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let fixture = try CredentialIdentityFixture(authority: authority, gate: gate)
        let task = Task { try await fixture.dependencies.restoreCredentialIdentity(a) }
        defer { task.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try fixture.dependencies.beginAccountChange(expectedCredentialTicket: a.ticket)
        }
        do {
            try await fixture.dependencies.restoreCredentialIdentity(a)
            Issue.record("Second activation acquired an occupied reservation")
        } catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(try authority.snapshot() == a)
        #expect(fixture.dependencies.accountGeneration == 17)
        #expect(fixture.dependencies.cachedUserId == nil)
        await gate.resume(); try await task.value
        #expect(fixture.dependencies.cachedUserId == DerivedUserID.from("A"))
    }

    @Test("stale restore has no identity or indexing effects on the replacement installation")
    func staleBeforeClaim() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let fixture = try CredentialIdentityFixture(authority: authority)
        let b = try installStagingCredentials("B", authority: authority)
        let bytes = storage.bytes
        do { try await fixture.dependencies.restoreCredentialIdentity(a); Issue.record("Stale restore accepted") }
        catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(try authority.snapshot() == b)
        #expect(storage.bytes == bytes)
        #expect(await fixture.index.clears == 0)
        #expect(fixture.dependencies.cachedUserId == nil)
        try await fixture.dependencies.restoreCredentialIdentity(b)
        #expect(fixture.dependencies.cachedUserId == DerivedUserID.from("B"))
    }

    @Test("failed durable installation compensates real account authorization and releases reservation")
    func persistenceFailureRevokesActualPermit() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let fixture = try CredentialIdentityFixture(authority: authority, ownerID: DerivedUserID.from("A"))
        let tx = try fixture.dependencies.beginAccountChange(expectedCredentialTicket: a.ticket)
        storage.failsWrites = true
        do {
            _ = try await fixture.dependencies.installCredentialSession(Session(token: "B", userId: "B", email: nil), refreshToken: nil, in: tx)
            Issue.record("Failed durable install accepted")
        } catch { #expect(error as? CredentialAuthenticationFailure == .unavailable(.securityStatus(-50))) }
        let denied = AccountMutationPermit(ownerID: DerivedUserID.from("B"), accountGeneration: tx.expectedAccountGeneration)
        await fixture.assertDenied(denied)
        #expect(!fixture.lifecycle.admits(ownerID: denied.ownerID, generation: denied.accountGeneration))
        #expect(fixture.dependencies.cachedUserId == DerivedUserID.from("A"))
        #expect(fixture.dependencies.activeAccountIdentity == nil)
        #expect(fixture.dependencies.pendingAccountChange === tx)
        storage.failsWrites = false
        let next = try fixture.dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        let b = try await fixture.dependencies.installCredentialSession(Session(token: "B-next", userId: "B", email: nil), refreshToken: nil, in: next)
        let newer = AccountMutationPermit(ownerID: DerivedUserID.from("B"), accountGeneration: next.expectedAccountGeneration)
        try await fixture.mutations.revoke(denied)
        try await fixture.assertAllowed(newer)
        #expect(try authority.snapshot() == b)
    }

    @Test("cancelled real Spotlight restore closes its permit and retries with a fresh local generation")
    func cancelAndRetryRestore() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let bytes = storage.bytes
        let gate = CredentialStagingGate()
        let fixture = try CredentialIdentityFixture(authority: authority, gate: gate)
        let old = AccountMutationPermit(ownerID: DerivedUserID.from("A"), accountGeneration: 17)
        try await fixture.mutations.activate(old)
        let task = Task { try await fixture.dependencies.restoreCredentialIdentity(a) }
        defer { task.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        task.cancel(); await gate.resume()
        do { try await task.value; Issue.record("Cancelled restore accepted") }
        catch { #expect(error is CancellationError) }
        await fixture.assertDenied(old)
        #expect(!fixture.lifecycle.admits(ownerID: old.ownerID, generation: old.accountGeneration))
        #expect(fixture.dependencies.activeAccountIdentity == nil)
        #expect(fixture.dependencies.accountGeneration == 18)
        #expect(try authority.snapshot() == a)
        #expect(storage.bytes == bytes)
        try await fixture.dependencies.restoreCredentialIdentity(a)
        let current = AccountMutationPermit(ownerID: old.ownerID, accountGeneration: 18)
        try await fixture.assertAllowed(current)
        try await fixture.mutations.revoke(old)
        try await fixture.assertAllowed(current)
        #expect(fixture.dependencies.cachedUserId == old.ownerID)
    }
}

@MainActor
@Suite("Credential retirement projection — owned completion only", .serialized, .timeLimit(.minutes(1)))
struct CredentialRetirementProjectionTests {
    @Test("pending projection never joins cleanup, then completion captures the new signed-out ticket", arguments: [false, true])
    func pendingAndCompleted(_ explicit: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(DerivedUserID.from("A")),
            accountGeneration: 17, persistAccountGeneration: { _ in }, credentialCleanup: { _ in await gate.suspend() })
        if explicit {
            let transaction = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
            #expect(deps.retireCredentialAccount(transaction) != nil)
        } else {
            guard case .admitted = deps.admitCredentialRejection(.invalidRefreshToken, context: a.rejectionContext) else {
                Issue.record("Rejection not admitted"); return
            }
        }
        let tx = try #require(deps.pendingAccountChange)
        let owned = try #require(tx.credentialTransition)
        if explicit { #expect(deps.credentialRetirementProjection(for: a.rejectionContext) == nil) }
        let task = try #require(deps.retireCredentialAccount(tx))
        defer { task.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        let pending = try #require((explicit ? deps.credentialRetirementProjection(for: owned) : deps.credentialRetirementProjection(for: a.rejectionContext)))
        guard case .pending = pending.status else { Issue.record("Expected pending projection"); return }
        #expect(pending.ticket == authority.attemptTicket())
        #expect(pending.transition.id == tx.credentialTransition?.id)
        #expect(deps.cachedUserId == DerivedUserID.from("A"))
        await gate.resume(); await task.value
        let done = try #require((explicit ? deps.credentialRetirementProjection(for: owned) : deps.credentialRetirementProjection(for: a.rejectionContext)))
        guard case .completed = done.status else { Issue.record("Expected completed projection"); return }
        #expect(done.transition.id == pending.transition.id)
        #expect(done.ticket == authority.attemptTicket())
        #expect(done.ticket != pending.ticket)
        #expect(authority.isCurrent(done.transition))
        #expect(deps.cachedUserId == nil && deps.pendingAccountChange == nil)
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try authority.snapshot() }
        let newer = try installStagingCredentials(explicit ? "B" : "A", authority: authority)
        #expect(newer.lease != a.lease)
        #expect((explicit ? deps.credentialRetirementProjection(for: owned) : deps.credentialRetirementProjection(for: a.rejectionContext)) == nil)
    }

    @Test("failed clear projects its current owner and explicit retry completes that same retirement", arguments: [false, true])
    func failedClearAndRetry(_ explicit: Bool) async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(DerivedUserID.from("A")),
            accountGeneration: 17, persistAccountGeneration: { _ in }, credentialCleanup: { _ in })
        storage.failsWrites = true
        if explicit {
            let transaction = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
            #expect(deps.retireCredentialAccount(transaction) != nil)
        } else {
            guard case .admitted = deps.admitCredentialRejection(.invalidRefreshToken, context: a.rejectionContext) else {
                Issue.record("Rejection not admitted"); return
            }
        }
        let tx = try #require(deps.pendingAccountChange)
        let owned = try #require(tx.credentialTransition)
        await (try #require(deps.retireCredentialAccount(tx))).value
        let failed = try #require((explicit ? deps.credentialRetirementProjection(for: owned) : deps.credentialRetirementProjection(for: a.rejectionContext)))
        guard case .failed(let error) = failed.status else { Issue.record("Expected failure projection"); return }
        #expect(error as? CredentialAuthenticationFailure == .unavailable(.securityStatus(-50)))
        #expect(failed.ticket == authority.attemptTicket())
        #expect(failed.transition.id == tx.credentialTransition?.id)
        #expect(deps.pendingAccountChange === tx)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot() }
        storage.failsWrites = false
        await (try #require(deps.retryCredentialRetirement())).value
        let done = try #require((explicit ? deps.credentialRetirementProjection(for: owned) : deps.credentialRetirementProjection(for: a.rejectionContext)))
        guard case .completed = done.status else { Issue.record("Expected completed retry"); return }
        #expect(done.transition.id == failed.transition.id)
        #expect(done.ticket != failed.ticket)
        #expect(deps.cachedUserId == nil)
    }

    @Test("new durable sign-in supersedes failed retirement without reviving its outgoing credentials", arguments: [false, true])
    func signInAfterFailedClear(_ explicit: Bool) async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let fixture = try CredentialIdentityFixture(authority: authority, ownerID: DerivedUserID.from("A"))
        let deps = fixture.dependencies
        storage.failsWrites = true
        if explicit {
            let transaction = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
            #expect(deps.retireCredentialAccount(transaction) != nil)
        } else {
            guard case .admitted = deps.admitCredentialRejection(.invalidRefreshToken, context: a.rejectionContext) else {
                Issue.record("Rejection not admitted"); return
            }
        }
        let original = try #require(deps.pendingAccountChange)
        let owned = try #require(original.credentialTransition)
        await (try #require(deps.retireCredentialAccount(original))).value
        storage.failsWrites = false
        let next = try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        let transition = try #require(next.credentialTransition)
        guard case .unavailable(let failure) = transition.outgoing else { Issue.record("Incomplete retirement credentials revived"); return }
        #expect(failure == .retirementIncomplete)
        let b = try await deps.installCredentialSession(Session(token: "B", userId: "B", email: nil), refreshToken: nil, in: next)
        #expect(try authority.snapshot() == b)
        #expect(deps.cachedUserId == DerivedUserID.from("B"))
        #expect((explicit ? deps.credentialRetirementProjection(for: owned) : deps.credentialRetirementProjection(for: a.rejectionContext)) == nil)
        #expect(deps.retryCredentialRetirement() == nil)
    }
}
