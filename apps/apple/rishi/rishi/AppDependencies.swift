import Foundation
import OSLog
import Observation















import SwiftUI

extension Notification.Name {
    static let rishiAccountDidChange = Notification.Name("rishi.account.didChange")
    static let rishiAccountTransitionStarted = Notification.Name("rishi.account.transitionStarted")
}

@MainActor
@Observable
final class AppDependencies {

    @MainActor static let shared = AppDependencies()

    private(set) var services: BootstrappedServices?
    private(set) var bootstrapFailure: Error?
    nonisolated private static let accountGenerationKey = "rishi.account.generation"
    private(set) var accountGeneration: UInt64
    private(set) var activeAccountIdentity: LibraryAccountIdentity?

    private var bootstrapTask: Task<Void, Never>?
    private var speechCatalogRefreshCoordinator: AppSpeechCatalogRefreshCoordinator?
    private var identityRequestToken: UInt64 = 0
    var pendingAccountChange: AccountChangeTransaction?
    private enum AccountEffectReservation {
        case transaction(AccountChangeTransaction)
        case restore(id: UUID, lease: CredentialLease)

        func owns(_ transaction: AccountChangeTransaction) -> Bool {
            guard case .transaction(let current) = self else { return false }
            return current === transaction
        }
    }
    @ObservationIgnored private var accountEffectReservation: AccountEffectReservation?
    @ObservationIgnored private var injectedIdentityResources: CredentialIdentityResources?
    let credentialAuthority: SessionCredentialAuthority
    @ObservationIgnored private let persistAccountGeneration: @Sendable (UInt64) -> Void
    private enum Construction: Sendable {
        case application
        case injected(@MainActor @Sendable (AccountChangeTransaction) async throws -> Void)
    }
    @ObservationIgnored private let construction: Construction
    private(set) var credentialAuthenticationAdapter: CredentialAuthenticationAdapter?
    private struct CredentialRetirement {
        let context: CredentialRejectionContext?
        let transaction: AccountChangeTransaction
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var credentialRetirement: CredentialRetirement?
    private(set) var credentialRetirementResult: Result<Void, Error>?
    private var synchronousAccountTransitionFences: [UUID: @MainActor () -> Void] = [:]
    private var postSharedReadingDrainHandlers: [UUID: @MainActor (UUID) async -> Void] = [:]
    private var carPlayAccountChangeObservers: [UUID: (CarPlayAccountSnapshot?) -> Void] = [:]

    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    let readerPositionSaveFailures = ReaderPositionSaveFailurePresentation()

    let macCommandRouter = MacCommandRouter()

    let macAccountMenu = MacAccountMenuModel()

    var cachedUserId: UUID? { userIdBox.value }

    public let userIdBox: UserIdBox

    @ObservationIgnored
    private lazy var _backgroundSyncLifecycle = BackgroundSyncLifecycle(
        dependencies: self,
        userIdBox: self.userIdBox
    )

    var backgroundSyncLifecycle: BackgroundSyncLifecycle {
        _backgroundSyncLifecycle
    }

    // Construct the one authority before bootstrap without reading credential storage.
    nonisolated init() {
        credentialAuthority = SessionCredentialAuthority(persistence: SecuritySessionCredentialPersistence())
        construction = .application
        userIdBox = UserIdBox()
        _accountGeneration = (UserDefaults.standard.object(forKey: Self.accountGenerationKey) as? NSNumber)?.uint64Value ?? 0
        persistAccountGeneration = { UserDefaults.standard.set($0, forKey: Self.accountGenerationKey) }
    }

    /// Inactive staging constructor: callers supply the single authority,
    /// identity box and generation storage. It never bootstraps live services.
    init(
        credentialAuthority: SessionCredentialAuthority,
        userIdBox: UserIdBox,
        accountGeneration: UInt64,
        persistAccountGeneration: @escaping @Sendable (UInt64) -> Void,
        credentialCleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void
    ) {
        self.credentialAuthority = credentialAuthority
        self.userIdBox = userIdBox
        self.accountGeneration = accountGeneration
        self.persistAccountGeneration = persistAccountGeneration
        self.construction = .injected(credentialCleanup)
        activeAccountIdentity = userIdBox.value.map { LibraryAccountIdentity(userID: $0, generation: accountGeneration) }
    }
    /// Identity activation requires its actual collaborators; cleanup-only fixtures
    /// retain the existing constructor and cannot publish an unactivated owner.
    convenience init(
        credentialAuthority: SessionCredentialAuthority, userIdBox: UserIdBox,
        accountGeneration: UInt64, persistAccountGeneration: @escaping @Sendable (UInt64) -> Void,
        credentialCleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void,
        identityResources: CredentialIdentityResources
    ) {
        self.init(credentialAuthority: credentialAuthority, userIdBox: userIdBox,
                  accountGeneration: accountGeneration, persistAccountGeneration: persistAccountGeneration,
                  credentialCleanup: credentialCleanup)
        injectedIdentityResources = identityResources
        _ = installSynchronousAccountTransitionFence { [weak self, lifecycle = identityResources.lifecycle] in
            guard let self, let ownerID = self.userIdBox.value else { return }
            _ = lifecycle.fenceAccount(ownerID: ownerID, generation: self.accountGeneration)
        }
    }

    /// Required adapters must share this exact authority, not merely equal leases.
    nonisolated func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool {
        credentialAuthority === authority
    }

    private var credentialIdentityResources: CredentialIdentityResources? {
        if let injectedIdentityResources { return injectedIdentityResources }
        guard let services else { return nil }
        return CredentialIdentityResources(
            spotlight: services.systemIntegration.spotlight,
            materialization: services.library.bookMaterializationCoordinator,
            lifecycle: services.library.bookImportLifecycle,
            mutations: services.library.scopedMutationStore
        )
    }

    @discardableResult
    func replaceUserId(_ newValue: UUID?, allowDeferredCleanup: Bool = false,
                       forceTransition: Bool = false, skipAccountFence: Bool = false) async -> Bool {
        // Compatibility callers must migrate to the captured credential operations.
        false
    }

    /// Synchronizes the CarPlay scene with the persisted identity. CarPlay
    /// can connect while the phone app is still alive, so an identity change
    /// must tear down the shared reader before exposing the new account.
    @discardableResult
    func synchronizeCarPlayIdentity(_ userID: UUID?) async -> Bool {
        guard userIdBox.value != userID else { return true }
        return await replaceUserId(userID)
    }

    /// Invalidates identity work synchronously, then begins the owner drain.
    /// The returned transaction is safe to await from a later Task.
    func beginAccountChange() throws -> AccountChangeTransaction {
        // A canonical transition requires the caller's original attempt ticket.
        throw CredentialAuthenticationFailure.accountChanged
    }

    /// Local admission precedes the credential fence; no suspension separates
    /// that fence from the existing identity/generation fence and owned drain.
    func beginAccountChange(
        expectedCredentialTicket: CredentialAttemptTicket,
        rejection: CredentialRejectionContext? = nil
    ) throws -> AccountChangeTransaction {
        guard accountEffectReservation == nil else {
            throw AccountDeletionCoordinatorError.accountChangedDuringDeletion
        }
        let outgoingNormalLease = (try? credentialAuthority.snapshot())?.lease
        let transition = try credentialAuthority.beginTransition(expected: expectedCredentialTicket, rejection: rejection)
        return commitAccountChange(credentialTransition: transition, outgoingNormalLease: outgoingNormalLease)
    }

    private func commitAccountChange(credentialTransition: CredentialTransition?, outgoingNormalLease: CredentialLease?) -> AccountChangeTransaction {
        let capturedLocalAccountID = userIdBox.value
        let credentialOwner: UUID?
        if let credentialTransition, case .loaded(let outgoing) = credentialTransition.outgoing {
            credentialOwner = DerivedUserID.from(outgoing.lease.rawUserID)
        } else { credentialOwner = nil }
        let outgoingAccount = capturedLocalAccountID ?? credentialOwner
        activeAccountIdentity = nil
        readerPositionSaveFailures.clear()
        let outgoingGeneration = accountGeneration
        let outgoingAccountMutationPermit = outgoingAccount.map {
            AccountMutationPermit(ownerID: $0, accountGeneration: outgoingGeneration)
        }
        for fence in synchronousAccountTransitionFences.values { fence() }
        if let outgoingAccountMutationPermit {
            (services?.library.scopedMutationStore ?? injectedIdentityResources?.mutations)?.closeAdmission(for: outgoingAccountMutationPermit)
        }
        identityRequestToken &+= 1
        incrementAccountGeneration()
        let services = self.services
        let identityResources = injectedIdentityResources
        let activationToken = outgoingAccount.map { ownerID in
            (services?.library.bookImportLifecycle ?? identityResources?.lifecycle)?.activationToken(ownerID: ownerID, generation: accountGeneration)
                ?? BookImportActivationToken(ownerID: ownerID, generation: accountGeneration, transitionEpoch: 0)
        }
        let postSharedReadingDrainHandlers = self.postSharedReadingDrainHandlers
        let drain = Task { @MainActor in
            if let services {
                if let outgoingAccount {
                    await services.sharedReadingSessionRegistry.drain(accountID: outgoingAccount)
                    // The registry has completed local close and its bounded
                    // remote leave window. Only now may UI routers release their
                    // detached live contexts and memory-only invitations.
                    for handler in postSharedReadingDrainHandlers.values {
                        await handler(outgoingAccount)
                    }
                }
                await services.audio.playbackOwner.stopForAccountChange()
            }
            if let outgoingAccountMutationPermit {
                try? await (services?.library.scopedMutationStore ?? identityResources?.mutations)?.revoke(outgoingAccountMutationPermit)
            }
            if let outgoingAccount {
                await (services?.library.bookImportLifecycle ?? identityResources?.lifecycle)?.drainAccount(outgoingAccount, generation: outgoingGeneration)
            }
        }
        let transaction = AccountChangeTransaction(
            expectedAccountGeneration: accountGeneration,
            outgoingAccountID: outgoingAccount,
            capturedLocalAccountID: capturedLocalAccountID,
            outgoingNormalCredentialLease: outgoingNormalLease,
            outgoingAccountGeneration: outgoingGeneration,
            activationToken: activationToken,
            outgoingAccountMutationPermit: outgoingAccountMutationPermit,
            credentialTransition: credentialTransition,
            drain: drain
        )
        pendingAccountChange = transaction
        return transaction
    }

    func installCredentialSession(
        _ session: Session, refreshToken: String?, in transaction: AccountChangeTransaction
    ) async throws -> CredentialSnapshot {
        let authority = credentialAuthority
        guard let resources = credentialIdentityResources else { throw CredentialIdentityActivationError.resourcesUnavailable }
        await transaction.drain.value
        try Task.checkCancellation()
        guard let transition = transaction.credentialTransition,
              isCurrentCredentialAccountChange(transaction), beginAccountCleanup(transaction) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        defer { endAccountCleanup(transaction) }
        if case .application = construction, transaction.outgoingAccountID != nil {
            try await cleanupCredentialAccount(transaction)
        }
        var installed: CredentialSnapshot?
        try await activateCredentialIdentity(
            ownerID: DerivedUserID.from(session.userId), generation: transaction.expectedAccountGeneration,
            resources: resources, isCurrent: { self.isCurrentCredentialAccountChange(transaction) }
        ) {
            let snapshot = try authority.install(session: session, refreshToken: refreshToken, in: transition)
            let userID = DerivedUserID.from(snapshot.lease.rawUserID)
            guard authority.performIfCurrent(snapshot.lease, mutation: {
                self.userIdBox.value = userID
                self.activeAccountIdentity = LibraryAccountIdentity(userID: userID, generation: self.accountGeneration)
                self.pendingAccountChange = nil
            }) else { throw CredentialAuthenticationFailure.accountChanged }
            installed = snapshot
        }
        guard let installed else { throw CredentialAuthenticationFailure.accountChanged }
        notifyCarPlayAccountChange()
        return installed
    }

    /// Cold restore activates the current installed owner; it never reinstalls
    /// credentials or creates an account-transition fence.
    func restoreCredentialIdentity(_ snapshot: CredentialSnapshot) async throws {
        let authority = credentialAuthority
        guard let resources = credentialIdentityResources else { throw CredentialIdentityActivationError.resourcesUnavailable }
        try Task.checkCancellation()
        let ownerID = DerivedUserID.from(snapshot.lease.rawUserID)
        guard pendingAccountChange == nil,
              accountEffectReservation == nil,
              userIdBox.value == nil || userIdBox.value == ownerID,
              try authority.snapshot(for: .normal(snapshot.lease)).ticket == snapshot.ticket else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        let id = UUID()
        let generation = accountGeneration
        accountEffectReservation = .restore(id: id, lease: snapshot.lease)
        defer {
            if case .restore(let current, _)? = accountEffectReservation, current == id { accountEffectReservation = nil }
        }
        do {
            try await activateCredentialIdentity(ownerID: ownerID, generation: generation, resources: resources,
                isCurrent: {
                    guard case .restore(let current, let lease)? = self.accountEffectReservation,
                          current == id, lease == snapshot.lease, self.accountGeneration == generation else { return false }
                    return authority.isCurrent(snapshot.lease)
                }) {
                    guard authority.performIfCurrent(snapshot.lease, mutation: {
                        self.userIdBox.value = ownerID
                        self.activeAccountIdentity = LibraryAccountIdentity(userID: ownerID, generation: generation)
                    }) else { throw CredentialAuthenticationFailure.accountChanged }
                }
            notifyCarPlayAccountChange()
        } catch {
            // An authorization closed on failure cannot be reused; retry gets
            // a fresh local generation while the credential lease stays intact.
            if case .restore(let current, _)? = accountEffectReservation, current == id {
                activeAccountIdentity = nil
                incrementAccountGeneration()
            }
            throw error
        }
    }

    private func activateCredentialIdentity(
        ownerID: UUID, generation: UInt64, resources: CredentialIdentityResources,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        commit: @escaping @MainActor @Sendable () throws -> Void
    ) async throws {
        let permit = AccountMutationPermit(ownerID: ownerID, accountGeneration: generation)
        var activationFailure: Error?
        let result = await resources.spotlight.transitionAccount {
            do {
                try Task.checkCancellation()
                guard isCurrent() else { throw CredentialAuthenticationFailure.accountChanged }
                try await resources.materialization.authorizeAccount(ownerID: ownerID, generation: generation)
                try Task.checkCancellation()
                guard isCurrent(), resources.lifecycle.activateAccount(ownerID: ownerID, generation: generation) else {
                    throw CredentialAuthenticationFailure.accountChanged
                }
                try commit()
                return true
            } catch {
                activationFailure = error
                return false
            }
        }
        guard result.identityApplied, result.cleanupComplete, activationFailure == nil else {
            resources.mutations.closeAdmission(for: permit)
            _ = resources.lifecycle.fenceAccount(ownerID: ownerID, generation: generation)
            do { try await resources.mutations.revoke(permit) }
            catch {
                await resources.lifecycle.drainAccount(ownerID, generation: generation)
                throw error
            }
            await resources.lifecycle.drainAccount(ownerID, generation: generation)
            if let activationFailure { throw activationFailure }
            try Task.checkCancellation()
            throw CredentialIdentityActivationError.spotlightCleanupIncomplete
        }
    }

    /// Actual UI/defaults mutation stays on its owner with no await after the
    /// lease comparison. The body must not call back into the authority.
    func performCredentialMutation(_ lease: CredentialLease, mutation: () -> Void) -> Bool {
        return credentialAuthority.performIfCurrent(lease, mutation: mutation)
    }

    func isCurrentCredentialAccountChange(_ transaction: AccountChangeTransaction) -> Bool {
        let authority = credentialAuthority
        guard
              let transition = transaction.credentialTransition else { return false }
        return authority.isCurrent(transition)
            && pendingAccountChange === transaction
            && accountGeneration == transaction.expectedAccountGeneration
            && userIdBox.value == transaction.capturedLocalAccountID
    }

    func restoreCredentialOwnerAfterDeletionFailure(_ transaction: AccountChangeTransaction) async throws {
        let authority = credentialAuthority
        guard
              let transition = transaction.credentialTransition,
              pendingAccountChange === transaction,
              accountGeneration == transaction.expectedAccountGeneration,
              (accountEffectReservation == nil || accountEffectReservation?.owns(transaction) == true) else { throw CredentialAuthenticationFailure.accountChanged }
        let restored = try authority.restoreOutgoing(in: transition)
        if let token = transaction.activationToken, let library = services?.library {
            try await library.scopedMutationStore.activate(AccountMutationPermit(ownerID: token.ownerID, accountGeneration: token.generation))
            guard authority.isCurrent(restored.lease), accountGeneration == transaction.expectedAccountGeneration,
                  library.bookImportLifecycle.activateAccount(token) else { throw CredentialAuthenticationFailure.accountChanged }
        }
        guard authority.performIfCurrent(restored.lease, mutation: {
            userIdBox.value = DerivedUserID.from(restored.lease.rawUserID)
            activeAccountIdentity = userIdBox.value.map { LibraryAccountIdentity(userID: $0, generation: accountGeneration) }
            pendingAccountChange = nil
        }) else { throw CredentialAuthenticationFailure.accountChanged }
    }

    /// Returns admission only. An initiating network/sync task must unwind
    /// before the owned completion joins any account cleanup work.
    func admitCredentialRejection(
        _ code: CredentialRejectionCode,
        context: CredentialRejectionContext
    ) -> CredentialRetirementAdmission {
        _ = code
        let authority = credentialAuthority
        if let existing = credentialRetirement,
           existing.context == context,
           let transition = existing.transaction.credentialTransition,
           authority.isCurrent(transition) {
            return .duplicate(transition.id)
        }
        guard let transaction = try? beginAccountChange(expectedCredentialTicket: context.ticket, rejection: context),
              let transition = transaction.credentialTransition else { return .stale }
        startCredentialRetirement(transaction, context: context)
        return .admitted(transition.id)
    }

    /// Read-only projection of the existing owned retirement. The initiating
    /// request never joins cleanup; UI consumes this on MainActor without an await.
    func credentialRetirementProjection(
        for rejection: CredentialRejectionContext
    ) -> CredentialRetirementProjection? {
        guard let retirement = credentialRetirement, retirement.context == rejection,
              let transition = retirement.transaction.credentialTransition else { return nil }
        return credentialRetirementProjection(for: transition)
    }

    /// Explicit sign-out/rollback retains its original transition. Reuse the
    /// same owned completion; never look up an ambient replacement for the UI.
    func credentialRetirementProjection(
        for original: CredentialTransition
    ) -> CredentialRetirementProjection? {
        let authority = credentialAuthority
        guard let retirement = credentialRetirement,
              let transition = retirement.transaction.credentialTransition,
              transition.id == original.id, transition.ticket == original.ticket,
              authority.isCurrent(transition),
              accountGeneration == retirement.transaction.expectedAccountGeneration else { return nil }
        let status: CredentialRetirementProjection.Status
        switch credentialRetirementResult {
        case .success?:
            guard pendingAccountChange == nil, userIdBox.value == nil else { return nil }
            status = .completed
        case .failure(let error)?:
            guard pendingAccountChange === retirement.transaction else { return nil }
            status = .failed(error)
        case nil:
            guard pendingAccountChange === retirement.transaction else { return nil }
            status = .pending
        }
        return CredentialRetirementProjection(transition: transition,
            ticket: authority.attemptTicket(), status: status)
    }

    func retireCredentialAccount(_ transaction: AccountChangeTransaction) -> Task<Void, Never>? {
        let authority = credentialAuthority
        guard let transition = transaction.credentialTransition,
              authority.isCurrent(transition) else { return nil }
        if let existing = credentialRetirement, existing.transaction === transaction { return existing.task }
        return startCredentialRetirement(transaction, context: nil)
    }

    /// Durable failure stays fenced and visible; retry reuses its transaction
    /// and cannot retire a subsequently installed account.
    func retryCredentialRetirement() -> Task<Void, Never>? {
        let authority = credentialAuthority
        guard let existing = credentialRetirement,
              case .failure? = credentialRetirementResult,
              let transition = existing.transaction.credentialTransition,
              authority.isCurrent(transition) else { return nil }
        return startCredentialRetirement(existing.transaction, context: existing.context)
    }

    @discardableResult
    private func startCredentialRetirement(
        _ transaction: AccountChangeTransaction,
        context: CredentialRejectionContext?
    ) -> Task<Void, Never> {
        credentialRetirementResult = nil
        let task = Task { @MainActor [weak self] in
            await transaction.drain.value
            guard let self, self.beginAccountCleanup(transaction) else { return }
            defer { self.endAccountCleanup(transaction) }
            do {
                switch self.construction {
                case .application: try await self.cleanupCredentialAccount(transaction)
                case .injected(let cleanup): try await cleanup(transaction)
                }
                try self.clearCredentialSessionAndIdentity(in: transaction)
                self.credentialRetirementResult = .success(())
            } catch {
                self.credentialRetirementResult = .failure(error)
            }
        }
        credentialRetirement = CredentialRetirement(context: context, transaction: transaction, task: task)
        return task
    }

    /// The reservation includes this final write/publication; callers release
    /// only after it returns, never before dispatching a later sign-out Task.
    func clearCredentialSessionAndIdentity(in transaction: AccountChangeTransaction) throws {
        let authority = credentialAuthority
        guard
              let transition = transaction.credentialTransition,
              accountEffectReservation?.owns(transaction) == true,
              pendingAccountChange === transaction else { throw CredentialAuthenticationFailure.accountChanged }
        switch authority.clear(in: transition) {
        case .superseded: throw CredentialAuthenticationFailure.accountChanged
        case .persistenceIncomplete(let failure): throw CredentialAuthenticationFailure.unavailable(failure)
        case .cleared: break
        }
        guard authority.performIfCurrent(transition, mutation: {
            userIdBox.value = nil
            activeAccountIdentity = nil
            pendingAccountChange = nil
        }) else { throw CredentialAuthenticationFailure.accountChanged }
        notifyCarPlayAccountChange()
    }

    /// A failed server deletion leaves the local identity signed in. Reopen
    /// its active generation and discard only the completed transition token
    /// that deletion just drained.
    func restoreOwnerAfterDeletionFailure(_ token: BookImportActivationToken) async {}

    /// Reserves global account cleanup after the server deletion succeeds.
    /// Identity transitions stay closed while purge operations suspend.
    func beginAccountDeletionCleanup(_ transaction: AccountChangeTransaction) -> Bool {
        beginAccountCleanup(transaction)
    }

    func beginAccountCleanup(_ transaction: AccountChangeTransaction) -> Bool {
        guard let transition = transaction.credentialTransition,
              credentialAuthority.isCurrent(transition) else { return false }
        return claimAccountCleanup(transaction)
    }

    private func claimAccountCleanup(_ transaction: AccountChangeTransaction) -> Bool {
        guard accountEffectReservation == nil,
              accountGeneration == transaction.expectedAccountGeneration,
              userIdBox.value == transaction.capturedLocalAccountID,
              pendingAccountChange === transaction else { return false }
        accountEffectReservation = .transaction(transaction)
        return true
    }

    /// Called synchronously immediately before the sign-out action. Both run
    /// on MainActor, so no other transition can interleave between release and
    /// the sign-out closure's start.
    func endAccountDeletionCleanup(_ transaction: AccountChangeTransaction) {
        endAccountCleanup(transaction)
    }

    func endAccountCleanup(_ transaction: AccountChangeTransaction) {
        guard accountEffectReservation?.owns(transaction) == true else { return }
        accountEffectReservation = nil
    }

    @discardableResult
    func installSynchronousAccountTransitionFence(
        _ fence: @escaping @MainActor () -> Void
    ) -> UUID {
        let token = UUID()
        synchronousAccountTransitionFences[token] = fence
        return token
    }

    func removeSynchronousAccountTransitionFence(_ token: UUID) {
        synchronousAccountTransitionFences.removeValue(forKey: token)
    }

    /// Registers account-scoped UI cleanup that must happen after, never
    /// before, the shared-reading registry's two-phase drain.
    @discardableResult
    func installPostSharedReadingDrainHandler(
        _ handler: @escaping @MainActor (UUID) async -> Void
    ) -> UUID {
        let token = UUID()
        postSharedReadingDrainHandlers[token] = handler
        return token
    }

    func removePostSharedReadingDrainHandler(_ token: UUID) {
        postSharedReadingDrainHandlers.removeValue(forKey: token)
    }

    func invalidateIdentityRequests() {
        _ = try? beginAccountChange()
    }

    @discardableResult
    func addCarPlayAccountChangeObserver(
        _ observer: @escaping (CarPlayAccountSnapshot?) -> Void
    ) -> UUID {
        let token = UUID()
        carPlayAccountChangeObservers[token] = observer
        return token
    }

    func removeCarPlayAccountChangeObserver(_ token: UUID) {
        carPlayAccountChangeObservers.removeValue(forKey: token)
    }

    func notifyCarPlayAccountChange() {
        let snapshot = carPlayAccountSnapshot
        for observer in carPlayAccountChangeObservers.values {
            observer(snapshot)
        }
        NotificationCenter.default.post(
            name: .rishiAccountDidChange,
            object: self,
            userInfo: [
                "generation": NSNumber(value: accountGeneration),
                "hasAccount": NSNumber(value: userIdBox.value != nil)
            ]
        )
    }

    private func incrementAccountGeneration() {
        accountGeneration &+= 1
        persistAccountGeneration(accountGeneration)
        NotificationCenter.default.post(
            name: .rishiAccountTransitionStarted,
            object: self,
            userInfo: ["generation": NSNumber(value: accountGeneration)]
        )
    }

    var carPlayAccountSnapshot: CarPlayAccountSnapshot? {
        guard let userID = userIdBox.value else { return nil }
        return CarPlayAccountSnapshot(userID: userID, generation: accountGeneration)
    }

    func bootstrap() async {
        guard case .application = construction else { return }
        if let inFlight = bootstrapTask {
            await inFlight.value
            return
        }
       
        

        let task = Task { [weak self] in
            guard let self else { return }
            let signpostId = Self.signposter.makeSignpostID()
            let state = Self.signposter.beginInterval(
                "cold-launch.bootstrap",
                id: signpostId
            )
            do {
            let authority = self.credentialAuthority
            let built = try await Self.makeServices(userIdBox: self.userIdBox, authority: authority,
                admitRejection: { [weak self] code, context in
                    guard let self else { return .stale }
                    return await self.admitCredentialRejection(code, context: context)
                })
            self.services = built
            self.credentialAuthenticationAdapter = try CredentialAuthenticationAdapter(
                    authority: authority, dependencies: self, worker: built.workerClient, consent: built.dataUseConsentStore,
                    installSession: { [weak self] session, refresh, transaction in
                        guard let self else { throw CredentialAuthenticationFailure.accountChanged }
                        return try await self.installCredentialSession(session, refreshToken: refresh, in: transaction)
                    }, restoreIdentity: { [weak self] snapshot in
                        guard let self else { throw CredentialAuthenticationFailure.accountChanged }
                        try await self.restoreCredentialIdentity(snapshot)
                        guard authority.isCurrent(snapshot.lease) else { throw CredentialAuthenticationFailure.accountChanged }
                        await built.voice.sessionRegistry.recoverPersistedSession()
                    }, registerPendingDeviceToken: { [weak self] snapshot in
                        guard let self else { throw CredentialAuthenticationFailure.accountChanged }
                        try await self.backgroundSyncLifecycle.retryPendingDeviceTokenIfAvailable(
                            platform: Self.devicePlatform, appVersion: Self.appVersion,
                            credentialContext: .normal(snapshot.lease))
                    }, completeDebugOnboarding: { snapshot in
                        guard await built.onboarding.state.setHasCompletedOnboarding(true, lease: snapshot.lease, authority: authority)
                        else { throw CredentialAuthenticationFailure.accountChanged }
                    }, refreshEntitlement: { snapshot in
                        guard await built.billing.entitlementService.bindToUser(userId: snapshot.lease.rawUserID, lease: snapshot.lease)
                        else { return }
                        _ = await built.billing.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .signIn, credentialContext: .normal(snapshot.lease))
                    })
            built.billing.customerEntitlements.startObserving()
            self.bootstrapFailure = nil
            let speechCatalogRefreshCoordinator = AppSpeechCatalogRefreshCoordinator(
                store: TTSPickerCatalogStore.shared,
                loader: { try await built.workerClient.send(SpeechOptionsEndpoint()) },
                isSuppressed: {
                    #if DEBUG
                    ProcessInfo.processInfo.environment["RISHI_E2E_REAL_AUTH"] == "1"
                    #else
                    false
                    #endif
                }
            )
            self.speechCatalogRefreshCoordinator = speechCatalogRefreshCoordinator
            speechCatalogRefreshCoordinator.start()
            if self.pendingAccountChange == nil, let userID = self.userIdBox.value {
                self.activeAccountIdentity = LibraryAccountIdentity(userID: userID, generation: self.accountGeneration)
            }
            _ = self.installSynchronousAccountTransitionFence { [weak self, lifecycle = built.library.bookImportLifecycle] in
                guard let self, let ownerID = self.userIdBox.value else { return }
                lifecycle.fenceAccount(ownerID: ownerID, generation: self.accountGeneration)
            }

            await built.voice.sessionRegistry.recoverPersistedSession()
            } catch {
                self.services?.billing.customerEntitlements.stopObserving()
                self.services = nil
                self.credentialAuthenticationAdapter = nil
                self.bootstrapFailure = error
                Log.error("app.bootstrap.failed", error: error)
            }
            Self.signposter.endInterval("cold-launch.bootstrap", state)
        }
        bootstrapTask = task
        await task.value
        if services == nil { bootstrapTask = nil }
    }

    func refreshEntitlementsAtLaunch() async {
        guard let coordinator = services?.billing.entitlementRefreshCoordinator,
              let snapshot = try? credentialAuthority.snapshot() else { return }
        _ = await coordinator.refreshIfSignedIn(reason: .launch, credentialContext: .normal(snapshot.lease))
    }

    nonisolated private static var devicePlatform: String {
        #if targetEnvironment(macCatalyst)
        "macos-catalyst"
        #else
        "ios"
        #endif
    }
    nonisolated private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
    nonisolated private static func makeServices(
        userIdBox: UserIdBox, authority: SessionCredentialAuthority,
        admitRejection: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission
    ) async throws -> BootstrappedServices {
        try await Task.detached(priority: .userInitiated) {
            try await ServiceGraphFactory.build(userIdBox: userIdBox, credentialAuthority: authority,
                                            admitCredentialRejection: admitRejection)
        }.value
    }

}

struct BootstrappedServices: @unchecked Sendable {

    let workerClient: WorkerClient
    let sharedReadingAPIFactory: @Sendable (CredentialRequestContext) throws -> SharedReadingAPI
    let sharedReadingSessionRegistry: SharedReadingSessionRegistry
    let dataUseConsentStore: any CredentialDataUseConsentStore

    let library: LibraryRuntime

    let audio: AudioRuntime

    let sync: SyncRuntime

    let chat: ChatRuntime

    let voice: VoiceRuntime

    let billing: BillingRuntime

    let settings: SettingsRuntime
    let onboarding: OnboardingRuntime
    let systemIntegration: SystemIntegrationRuntime
}


struct SettingsRuntime: @unchecked Sendable {
    let readerDefaults: AppReaderDefaults
    let telemetryStore: any TelemetryStore
    let footerDetectionStore: any FooterDetectionStore
}

struct OnboardingRuntime: @unchecked Sendable {
    let state: any CredentialOnboardingState
    let trialState: any TrialOnboardingState
    let coordinator: OnboardingCoordinator
}

struct VoiceRuntime: @unchecked Sendable {
    let presenter: VoiceSessionPresenter
    let sessionRegistry: VoiceSessionRegistry
}

struct AudioRuntime: @unchecked Sendable {
    let coordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: any TTSPlaying
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController
    let ttsPresenceController: TTSPresenceController
    let ttsPrewarmer: TTSPrewarmer
    let playbackOwner: ReadAloudPlaybackOwner
}

struct ChatRuntime: @unchecked Sendable {
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let conversationLookup: ConversationLookup
    let service: RishiChatService
}

struct LibraryRuntime: @unchecked Sendable {
    let dbStore: RishiDBStore
    let scopedMutationStore: BookScopedMutationStore
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookmarkStore: any BookmarkStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let readerSettingsStore: any SynchronousReaderSettingsStore
    let chapterIndexPersistence: any ChapterIndexPersistence
    let chapterSummarizer: ChapterSummarizer
    let epubUnpackedCache: EPUBUnpackedCache
    let bookSearch: any BookSearch
    let indexingHook: any BookIndexingHook
    let sharePackageService: SharePackageService
    let sessionBookService: SessionBookService
    let bookSourceRegistry: BookSourceRegistry
    let bookImportLifecycle: BookImportLifecycle
    let bookMaterializationCoordinator: BookMaterializationCoordinator
    let bookImportEvents: BookImportEvents
    let currentAccountGeneration: @Sendable () async -> UInt64?
    let bookImportRecovery: BookImportRecovery
}

struct SyncRuntime: @unchecked Sendable {
    let metadataStore: any SyncMetadataStore
    let status: SyncStatus
    let engine: SyncEngine
    let backgroundTaskCoordinator: BackgroundTaskCoordinator
    let chapterIndexGenerationDispatcher: ChapterIndexGenerationDispatcher
    let apnsDeviceRegistrar: APNsDeviceRegistrar
    let chatRefreshAdapter: AppChatRefreshAdapter
}

struct BillingRuntime: @unchecked Sendable {
    let customerEntitlements: CustomerEntitlements
    let store: Store
    let entitlementService: EntitlementService
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let manageSubscriptionPresenter: ManageSubscriptionPresenter
    let entitlementReconciler: EntitlementReconciler
    let readerAppEntitlementFlag: ReaderAppEntitlementFlag
    let restoreService: RestoreService
    let workerReceiptVerifier: any ReceiptVerifier
    let groupID: Optional<GroupId>
}

@MainActor
final class UserIdBox {
    var value: UUID? = nil

    nonisolated init(
        _ value: UUID? = nil
    ) {
        
        self.value =  value
    }
}

private struct RishiAuthServiceKey: EnvironmentKey {
    static let defaultValue: (any AuthService)? = nil
}

extension EnvironmentValues {
    var rishiAuthService: (any AuthService)? {
        get { self[RishiAuthServiceKey.self] }
        set { self[RishiAuthServiceKey.self] = newValue }
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}

private struct ServicesKey: EnvironmentKey {
    static let defaultValue: BootstrappedServices? = nil
}

extension EnvironmentValues {
    var services: BootstrappedServices? {
        get { self[ServicesKey.self] }
        set { self[ServicesKey.self] = newValue }
    }
}

private struct CurrentUserKey: EnvironmentKey {
    static let defaultValue: User? = nil
}

extension EnvironmentValues {
    var currentUser: User? {
        get { self[CurrentUserKey.self] }
        set { self[CurrentUserKey.self] = newValue }
    }
}

private struct SignOutActionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var signOut: () -> Void {
        get { self[SignOutActionKey.self] }
        set { self[SignOutActionKey.self] = newValue }
    }
}

/// Actual identity-effect collaborators, shared with the existing service graph.
struct CredentialIdentityResources: Sendable {
    let spotlight: RishiSpotlightCoordinator
    let materialization: BookMaterializationCoordinator
    let lifecycle: BookImportLifecycle
    let mutations: BookScopedMutationStore
}

enum CredentialIdentityActivationError: Error, Sendable {
    case resourcesUnavailable
    case spotlightCleanupIncomplete
}

struct CredentialRetirementProjection {
    enum Status { case pending, completed, failed(Error) }
    let transition: CredentialTransition
    let ticket: CredentialAttemptTicket
    let status: Status
}
