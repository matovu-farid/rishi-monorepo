import Foundation
import Testing
@testable import rishi

private actor PurgeGenerationProbe {
    private(set) var calls: [UInt64] = []
    func record(_ generation: UInt64) { calls.append(generation) }
    func last() -> UInt64? { calls.last }
}

private actor DeletionEventProbe {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor ActivationTokenProbe {
    private(set) var generation: UInt64?
    func record(_ token: BookImportActivationToken) { generation = token.generation }
}

private enum AccountDeletionTestError: Error {
    case serverDeleteFailed
}

private final class DeletionIdentityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ownerID: UUID?
    private var generation: UInt64
    private var purgeCount = 0
    private var didSignOut = false
    private var transitionWasBlocked = false

    init(ownerID: UUID?, generation: UInt64) {
        self.ownerID = ownerID
        self.generation = generation
    }

    func setIdentity(ownerID: UUID?, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.ownerID = ownerID
        self.generation = generation
    }

    func matches(ownerID expectedOwnerID: UUID?, generation expectedGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ownerID == expectedOwnerID && generation == expectedGeneration
    }

    func recordPurge() {
        lock.lock(); defer { lock.unlock() }
        purgeCount += 1
    }

    func recordSignOut() {
        lock.lock(); defer { lock.unlock() }
        didSignOut = true
    }

    func recordTransitionAttempt(blocked: Bool) {
        lock.lock(); defer { lock.unlock() }
        transitionWasBlocked = blocked
    }

    func cleanupState() -> (purgeCount: Int, didSignOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (purgeCount, didSignOut)
    }

    func transitionAttemptWasBlocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transitionWasBlocked
    }
}

@Suite("Account change fencing")
@MainActor
struct AccountChangeTransactionTests {
    @Test("the generation fence is committed before the drain task")
    func beginsSynchronously() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let fixture = try CredentialIdentityFixture(authority: authority)
        let dependencies = fixture.dependencies
        let previousGeneration = dependencies.accountGeneration
        let transaction = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        #expect(transaction.expectedAccountGeneration == previousGeneration + 1)
        #expect(dependencies.accountGeneration == transaction.expectedAccountGeneration)
        await transaction.drain.value
    }

    @Test("active library identity stays gated during a transition and reactivates on commit")
    func activeLibraryIdentityTracksCommittedAccount() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let fixture = try CredentialIdentityFixture(authority: authority)
        let dependencies = fixture.dependencies
        let userID = UUID()
        let installation = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        _ = try await dependencies.installCredentialSession(Session(token: "fixture", userId: userID.uuidString, email: nil), refreshToken: nil, in: installation)
        #expect(dependencies.userIdBox.value == userID)
        let firstIdentity = dependencies.activeAccountIdentity
        #expect(firstIdentity?.userID == userID)

        let transition = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        #expect(dependencies.activeAccountIdentity == nil)
        await transition.drain.value

        _ = try await dependencies.installCredentialSession(Session(token: "fixture-rotated", userId: userID.uuidString, email: nil), refreshToken: nil, in: transition)
        #expect(dependencies.userIdBox.value == userID)
        #expect(dependencies.activeAccountIdentity?.userID == userID)
        #expect(dependencies.activeAccountIdentity?.generation == dependencies.accountGeneration)
        #expect(dependencies.activeAccountIdentity?.generation != firstIdentity?.generation)
    }

    @Test("account deletion purges using the transaction's outgoing generation")
    func deletionUsesOutgoingGeneration() async throws {
        let probe = PurgeGenerationProbe()
        let coordinator = AccountDeletionCoordinator(
            deleteServer: {},
            purgeLocal: {},
            purgeLocalForGeneration: { await probe.record($0); return nil },
            signOut: {},
            beginAccountChange: {
                AccountChangeTransaction(expectedAccountGeneration: 43, outgoingAccountID: UUID(), outgoingAccountGeneration: 42, drain: Task {})
            }
        )

        try await coordinator.run()
        #expect(await probe.last() == 42)
    }

    @Test("account deletion waits for transition drains before server deletion and purge")
    func deletionDrainsBeforeServerAndPurge() async throws {
        let events = DeletionEventProbe()
        let ownerID = UUID()
        let transaction = AccountChangeTransaction(
            expectedAccountGeneration: 8,
            outgoingAccountID: ownerID,
            outgoingAccountGeneration: 7,
            outgoingAccountMutationPermit: AccountMutationPermit(ownerID: ownerID, accountGeneration: 7),
            drain: Task { await events.record("drained") }
        )
        let coordinator = AccountDeletionCoordinator(
            deleteServer: { await events.record("server") },
            purgeLocal: { await events.record("purge") },
            signOut: {},
            beginAccountChange: { transaction }
        )

        try await coordinator.run()
        #expect(await events.events == ["drained", "server", "purge"])
    }

    @Test("local-only purge has no synthetic previous generation")
    func localOnlyPurgeDoesNotSubtractGeneration() async throws {
        let probe = PurgeGenerationProbe()
        let coordinator = AccountDeletionCoordinator(
            deleteServer: {},
            purgeLocal: {},
            purgeLocalForGeneration: { await probe.record($0); return nil },
            currentAccountGeneration: { 29 },
            signOut: {}
        )

        try await coordinator.purgeLocalOnly()
        #expect(await probe.last() == 29)
    }

    @Test("local-only purge reopens the post-transition generation")
    func localOnlyPurgeReopensCurrentGeneration() async throws {
        let userID = UUID()
        let activated = ActivationTokenProbe()
        let coordinator = AccountDeletionCoordinator(
            deleteServer: {},
            purgeLocal: {},
            purgeLocalForGeneration: { generation in
                #expect(generation == 29)
                return BookImportActivationToken(ownerID: userID, generation: 29, transitionEpoch: 4)
            },
            currentAccountGeneration: { 29 },
            reactivateLocalOwner: { await activated.record($0) },
            signOut: {},
            beginAccountChange: {
                AccountChangeTransaction(
                    expectedAccountGeneration: 30,
                    outgoingAccountID: userID,
                    outgoingAccountGeneration: 29,
                    activationToken: BookImportActivationToken(ownerID: userID, generation: 30, transitionEpoch: 4),
                    drain: Task {}
                )
            }
        )

        try await coordinator.purgeLocalOnly()
        #expect(await activated.generation == 30)
    }

    @Test("successful local-only purge reopens the same account generation")
    func localOnlyPurgeReactivatesGeneration() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "After reset", formatType: .pdf, fileURL: "Books/after-reset.pdf")
        let registry = BookSourceRegistry(currentGeneration: { 29 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { 29 })
        lifecycle.fenceAccount(ownerID: userID, generation: 29)
        await lifecycle.drainAccount(userID, generation: 29)

        let coordinator = AccountDeletionCoordinator(
            deleteServer: {},
            purgeLocal: {},
            purgeLocalForGeneration: { _ in lifecycle.activationToken(ownerID: userID, generation: 29) },
            currentAccountGeneration: { 29 },
            reactivateLocalOwner: { token in _ = lifecycle.activateAccount(token) },
            signOut: {}
        )
        try await coordinator.purgeLocalOnly()

        let operation = try #require(lifecycle.admitOwnerOperation(ownerID: userID, generation: 29))
        operation.release()
        try await registry.registerSource(
            for: book,
            url: URL(fileURLWithPath: "/tmp/reimported.pdf"),
            accountGeneration: 29,
            readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 29, bookID: book.id, contentRevision: UUID()),
            requiresSecurityScope: false,
            observeChanges: false
        )
        let source = try await registry.acquireReadableSource(for: book)
        #expect(source.url == URL(fileURLWithPath: "/tmp/reimported.pdf"))
    }

    @Test("server deletion failure restores admission for the signed-in account generation")
    func serverDeleteFailureReactivatesOwner() async throws {
        let userID = UUID()
        let registry = BookSourceRegistry(currentGeneration: { 43 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { 43 })
        let coordinator = AccountDeletionCoordinator(
            deleteServer: { throw AccountDeletionTestError.serverDeleteFailed },
            purgeLocal: {},
            purgeLocalForGeneration: { _ in nil },
            currentAccountGeneration: { 43 },
            reactivateLocalOwner: { token in _ = lifecycle.activateAccount(token) },
            signOut: {},
            beginAccountChange: {
                let activeToken = lifecycle.fenceAccount(ownerID: userID, generation: 42)
                let drain = Task { await lifecycle.drainAccount(userID, generation: 42) }
                let token = BookImportActivationToken(ownerID: activeToken.ownerID, generation: 43, transitionEpoch: activeToken.transitionEpoch)
                return AccountChangeTransaction(expectedAccountGeneration: 43, outgoingAccountID: userID, outgoingAccountGeneration: 42, activationToken: token, drain: drain)
            }
        )

        await #expect(throws: AccountDeletionTestError.serverDeleteFailed) { try await coordinator.run() }
        #expect(lifecycle.admits(ownerID: userID, generation: 43))
        #expect(!lifecycle.admits(ownerID: userID, generation: 42))
    }

    @Test("sign-out after failed deletion begins a fresh active-generation drain")
    func signOutAfterDeleteFailureUsesFreshTransaction() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let fixture = try CredentialIdentityFixture(authority: authority)
        let dependencies = fixture.dependencies
        let userID = UUID()
        let session = try installStagingCredentials(userID.uuidString, authority: authority)
        try await dependencies.restoreCredentialIdentity(session)
        let activeGeneration = dependencies.accountGeneration + 1
        let coordinator = AccountDeletionCoordinator(
            admittedDeleteServer: { _ in throw AccountDeletionTestError.serverDeleteFailed },
            purgeLocal: { _ in },
            restoreOwner: { try await dependencies.restoreCredentialOwnerAfterDeletionFailure($0) },
            isCurrent: { dependencies.isCurrentCredentialAccountChange($0) },
            beginCleanup: { dependencies.beginAccountCleanup($0) },
            endCleanup: { dependencies.endAccountCleanup($0) },
            signOut: { try dependencies.clearCredentialSessionAndIdentity(in: $0) },
            beginChange: { try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket()) }
        )

        await #expect(throws: AccountDeletionTestError.serverDeleteFailed) { try await coordinator.run() }
        #expect(dependencies.pendingAccountChange == nil)
        #expect(dependencies.activeAccountIdentity == LibraryAccountIdentity(userID: userID, generation: activeGeneration))

        let signOutTransition = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        #expect(signOutTransition.outgoingAccountID == userID)
        #expect(signOutTransition.outgoingAccountGeneration == activeGeneration)
        #expect(signOutTransition.expectedAccountGeneration == activeGeneration + 1)
        await signOutTransition.drain.value
    }

    @Test("delayed deletion failure cannot reopen a newer account transition")
    func delayedDeleteFailureCannotReactivateNewerTransition() async throws {
        let userID = UUID()
        let registry = BookSourceRegistry(currentGeneration: { 43 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { 43 })
        let outgoingToken = lifecycle.fenceAccount(ownerID: userID, generation: 42)
        let delayedRecovery = BookImportActivationToken(ownerID: userID, generation: 43, transitionEpoch: outgoingToken.transitionEpoch)

        _ = lifecycle.fenceAccount(ownerID: userID, generation: 43)

        #expect(!lifecycle.activateAccount(delayedRecovery))
        #expect(!lifecycle.admits(ownerID: userID, generation: 43))
    }

    @Test("local-only purge activation cannot reopen a concurrent transition")
    func localOnlyPurgeCannotReactivateAfterConcurrentTransition() async throws {
        let userID = UUID()
        let registry = BookSourceRegistry(currentGeneration: { 30 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { 30 })
        let purgeToken = lifecycle.fenceAccount(ownerID: userID, generation: 29)

        _ = lifecycle.fenceAccount(ownerID: userID, generation: 30)

        let stalePurgeToken = BookImportActivationToken(ownerID: userID, generation: 30, transitionEpoch: purgeToken.transitionEpoch)
        #expect(!lifecycle.activateAccount(stalePurgeToken))
        #expect(!lifecycle.admits(ownerID: userID, generation: 30))
    }

    @Test("successful delayed deletion cannot purge or sign out a newer identity")
    func delayedDeleteSuccessDoesNotTouchNewIdentity() async throws {
        let deletingOwner = UUID()
        let newerOwner = UUID()
        let probe = DeletionIdentityProbe(ownerID: deletingOwner, generation: 44)
        let transaction = AccountChangeTransaction(
            expectedAccountGeneration: 44,
            outgoingAccountID: deletingOwner,
            outgoingAccountGeneration: 43,
            activationToken: BookImportActivationToken(ownerID: deletingOwner, generation: 44, transitionEpoch: 1),
            drain: Task {}
        )
        let coordinator = AccountDeletionCoordinator(
            deleteServer: { probe.setIdentity(ownerID: newerOwner, generation: 45) },
            purgeLocal: { probe.recordPurge() },
            purgeLocalForGeneration: { _ in probe.recordPurge(); return nil },
            currentAccountGeneration: { 45 },
            beginAccountDeletionCleanup: { probe.matches(ownerID: $0.outgoingAccountID, generation: $0.expectedAccountGeneration) },
            signOut: { probe.recordSignOut() },
            beginAccountChange: { transaction }
        )

        await #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try await coordinator.run()
        }
        let cleanup = probe.cleanupState()
        #expect(cleanup.purgeCount == 0)
        #expect(!cleanup.didSignOut)
    }

    @Test("identity transitions are blocked throughout global deletion cleanup")
    func identityTransitionIsBlockedDuringCleanup() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let fixture = try CredentialIdentityFixture(authority: authority)
        let dependencies = fixture.dependencies
        let ownerID = UUID()
        let session = try installStagingCredentials(ownerID.uuidString, authority: authority)
        try await dependencies.restoreCredentialIdentity(session)
        let probe = DeletionIdentityProbe(ownerID: nil, generation: 0)
        let coordinator = AccountDeletionCoordinator(
            deleteServer: {},
            purgeLocal: {},
            purgeLocalForGeneration: { _ in
                let blocked = await MainActor.run {
                    do {
                        _ = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
                        return false
                    } catch {
                        return true
                    }
                }
                probe.recordTransitionAttempt(blocked: blocked)
                return nil
            },
            beginAccountDeletionCleanup: { dependencies.beginAccountDeletionCleanup($0) },
            endAccountDeletionCleanup: { dependencies.endAccountDeletionCleanup($0) },
            signOut: {},
            beginAccountChange: { try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket()) }
        )

        try await coordinator.run()
        #expect(probe.transitionAttemptWasBlocked())
        let laterTransition = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        #expect(laterTransition.outgoingAccountID == ownerID)
    }
}
