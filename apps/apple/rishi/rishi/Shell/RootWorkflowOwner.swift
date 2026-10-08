import Foundation
import Observation

/// Root-scoped inputs and presentation. Existing auth, package and registry
/// owners retain their persistence, admission and teardown responsibilities.
@MainActor
@Observable
final class RootWorkflowOwner {
    struct Resources {
        let packages: SharePackageService
        let prepareBook: @MainActor (SharedReadingBook, UUID) async throws -> SessionBookService.PreparedBook
        let api: @Sendable (CredentialRequestContext) throws -> SharedReadingAPI
        let registry: SharedReadingSessionRegistry
        let pendingInvites: PendingSessionInviteStore
        let makeTransport: @MainActor @Sendable () -> any SharedReadingSignalingTransport
    }

    @MainActor
    struct Host {
        let router: AppRouter
        #if targetEnvironment(macCatalyst)
        let readerWindows: ReaderWindowCoordinator
        #endif

        func detach(accountID: UUID) {
            router.detachSharedReaderPresentation(for: accountID)
            #if targetEnvironment(macCatalyst)
            readerWindows.detachSharedReading(for: accountID)
            #endif
        }

        func clearDetached(accountID: UUID) {
            router.clearDetachedSharedReaderContexts(for: accountID)
            #if targetEnvironment(macCatalyst)
            readerWindows.clearDetachedSharedReading(for: accountID)
            #endif
        }

        var cleanupAfterDrain: @MainActor (UUID) async -> Void {
            { [self] accountID in self.clearDetached(accountID: accountID) }
        }

        func activeRoute(for accountID: UUID) -> SharedReadingReaderRoute? {
            #if targetEnvironment(macCatalyst)
            let route = router.catalystSharedReaderRoute
            #else
            let route = router.sharedReaderRoute
            #endif
            return route?.accountID == accountID ? route : nil
        }

        func isActive(_ sessionID: String, accountID: UUID) -> Bool {
            activeRoute(for: accountID)?.sessionID == sessionID
        }
    }

    struct StartupReadTicket: Sendable, Equatable {
        let id: UUID
        let rootID: UUID
        let identity: LibraryAccountIdentity
        let inputRevision: UInt64
    }

    struct SessionAttemptTicket: Sendable, Equatable {
        let id: UUID
        let rootID: UUID
        let identity: LibraryAccountIdentity
        let lease: CredentialLease
        let token: String

        func hasSameInput(as other: Self) -> Bool {
            rootID == other.rootID && identity == other.identity
                && lease == other.lease && token == other.token
        }
    }

    private struct Invitation {
        let identity: LibraryAccountIdentity
        let value: SharedReadingInvitation
    }

    let rootID = UUID()
    private(set) var pendingToken: String?
    private(set) var alertTitle = "Shared books"
    private(set) var alertMessage: String?
    private(set) var isRetired = false
    private(set) var identity: LibraryAccountIdentity?
    private(set) var onboardingPresented = false
    private var inputRevision: UInt64 = 0
    private var invitations: [String: Invitation] = [:]
    private var startupRead: StartupReadTicket?
    private var activeAttempt: SessionAttempt?
    private var attemptTask: Task<Void, Never>?
    private var fenceToken: UUID?
    private var drainToken: UUID?
    private let dependencies: AppDependencies
    private let authentication: CredentialAuthenticationAdapter
    private let currentUser: CurrentUserBox
    private let resources: Resources
    private let host: Host

    init(dependencies: AppDependencies, authentication: CredentialAuthenticationAdapter,
         currentUser: CurrentUserBox, resources: Resources, host: Host) throws {
        guard authentication.appDependencies === dependencies,
              dependencies.usesCredentialAuthority(authentication.authority) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        self.dependencies = dependencies
        self.authentication = authentication
        self.currentUser = currentUser
        self.resources = resources
        self.host = host
    }

    private var signedInIdentity: LibraryAccountIdentity? {
        guard case .signedIn(let user) = currentUser.state,
              let identity = dependencies.activeAccountIdentity,
              identity.userID == user.id else { return nil }
        return identity
    }

    var hasPendingInvitation: Bool { !invitations.isEmpty }
    var isRedeeming: Bool { activeAttempt != nil }

    func start() {
        guard !isRetired, fenceToken == nil else { return }
        fenceToken = dependencies.installSynchronousAccountTransitionFence { [weak self] in
            self?.fenceAccountPresentation()
        }
        // AppDependencies snapshots this callback before registry drain. Its
        // concrete cleanup survives removal of the live root's registration.
        drainToken = dependencies.installPostSharedReadingDrainHandler(host.cleanupAfterDrain)
    }

    func updateEligibility(identity next: LibraryAccountIdentity?, onboardingPresented: Bool) {
        guard !isRetired else { return }
        if identity != next {
            if let old = identity { host.detach(accountID: old.userID) }
            inputRevision &+= 1
            startupRead = nil
            activeAttempt = nil
            attemptTask = nil
            invitations = [:]
            alertMessage = nil
        }
        identity = next
        self.onboardingPresented = onboardingPresented
        schedulePendingSessionIfEligible()
    }

    func restoreAndLoadPendingIfEligible() async {
        guard !isRetired else { return }
        switch currentUser.state {
        case .signedOut, .authenticationRecovery: await authentication.restore(into: currentUser)
        case .loading, .signedIn: break
        }
        guard !isRetired else { return }
        updateEligibility(identity: signedInIdentity,
                          onboardingPresented: onboardingPresented)
        await loadPendingIfEligible()
    }

    func loadPendingIfEligible() async {
        guard !isRetired, currentUser.isSigned, let identity,
              identity == signedInIdentity else { return }
        let ticket = StartupReadTicket(id: UUID(), rootID: rootID,
                                       identity: identity, inputRevision: inputRevision)
        startupRead = ticket
        let token = await resources.pendingInvites.load()
        guard accepts(ticket) else { return }
        startupRead = nil
        if pendingToken == nil, let token { pendingToken = token }
        schedulePendingSessionIfEligible()
        let redemption = attemptTask
        await redeemPendingPackages()
        await redemption?.value
    }

    @discardableResult
    func queueSessionToken(_ token: String) -> Task<Void, Never>? {
        guard !isRetired, !token.isEmpty else { return nil }
        inputRevision &+= 1
        startupRead = nil
        pendingToken = token
        schedulePendingSessionIfEligible()
        return attemptTask
    }

    func queueInvitation(_ invitation: SharedReadingInvitation, identity: LibraryAccountIdentity) {
        guard !isRetired, self.identity == identity,
              signedInIdentity == identity else { return }
        invitations[invitation.sessionID] = Invitation(identity: identity, value: invitation)
    }

    func dismissAlert() { alertMessage = nil }

    func redeemPendingPackages() async {
        // Explicit book sharing continues during optional onboarding.
        guard !isRetired, currentUser.isSigned, let identity,
              signedInIdentity == identity,
              let snapshot = try? authentication.authority.snapshot(),
              DerivedUserID.from(snapshot.lease.rawUserID) == identity.userID else { return }
        let revision = inputRevision
        let result = await resources.packages.redeemPendingIfEligible()
        guard !isRetired, self.identity == identity, signedInIdentity == identity,
              inputRevision == revision, authentication.authority.isCurrent(snapshot.lease),
              result.discardedCount > 0 else { return }
        alertTitle = "Shared books"
        if result.alreadyUsedCount > 0 {
            alertMessage = result.alreadyUsedCount == 1
                ? "This one-time shared link has already been used."
                : "These one-time shared links have already been used."
        } else {
            alertMessage = result.discardedCount == 1
                ? "One shared link is expired or no longer available."
                : "\(result.discardedCount) shared links are expired or no longer available."
        }
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        inputRevision &+= 1
        startupRead = nil
        activeAttempt = nil
        attemptTask = nil
        invitations = [:]
        alertMessage = nil
        if let fenceToken { dependencies.removeSynchronousAccountTransitionFence(fenceToken) }
        if let drainToken { dependencies.removePostSharedReadingDrainHandler(drainToken) }
        fenceToken = nil
        drainToken = nil
        // No cancellation: an admitted server receipt still needs compensation.
    }

    private func fenceAccountPresentation() {
        guard !isRetired else { return }
        if let identity { host.detach(accountID: identity.userID) }
        inputRevision &+= 1
        startupRead = nil
        activeAttempt = nil
        attemptTask = nil
        invitations = [:]
        alertMessage = nil
    }

    private func accepts(_ ticket: StartupReadTicket) -> Bool {
        !isRetired && !Task.isCancelled && ticket == startupRead && ticket.rootID == rootID
            && ticket.identity == identity && ticket.identity == dependencies.activeAccountIdentity
            && ticket.inputRevision == inputRevision && signedInIdentity == ticket.identity
    }

    private func accepts(_ ticket: SessionAttemptTicket) -> Bool {
        !isRetired && !Task.isCancelled && ticket.rootID == rootID
            && activeAttempt?.ticket == ticket && pendingToken == ticket.token
            && ticket.identity == identity && ticket.identity == dependencies.activeAccountIdentity
            && dependencies.cachedUserId == ticket.identity.userID
            && dependencies.accountGeneration == ticket.identity.generation
            && authentication.authority.isCurrent(ticket.lease) && signedInIdentity == ticket.identity
    }

    private func schedulePendingSessionIfEligible() {
        guard !isRetired, currentUser.isSigned, !onboardingPresented,
              let identity, signedInIdentity == identity, let token = pendingToken,
              let snapshot = try? authentication.authority.snapshot(),
              DerivedUserID.from(snapshot.lease.rawUserID) == identity.userID else { return }
        let ticket = SessionAttemptTicket(id: UUID(), rootID: rootID, identity: identity,
                                         lease: snapshot.lease, token: token)
        guard activeAttempt?.ticket.hasSameInput(as: ticket) != true else { return }
        let attempt = SessionAttempt(ticket: ticket, owner: self, dependencies: dependencies,
                                     resources: resources, host: host)
        activeAttempt = attempt
        attemptTask = Task { @MainActor [attempt, weak self] in
            await attempt.run()
            guard self?.activeAttempt === attempt else { return }
            self?.activeAttempt = nil
            self?.attemptTask = nil
        }
    }

    private func invitation(for sessionID: String, ticket: SessionAttemptTicket) -> SharedReadingInvitation? {
        guard accepts(ticket), let invitation = invitations[sessionID],
              invitation.identity == ticket.identity else { return nil }
        return invitation.value
    }

    private func clearPending(ifCurrent ticket: SessionAttemptTicket, sessionID: String?) async {
        guard accepts(ticket) else { return }
        pendingToken = nil
        if let sessionID { invitations.removeValue(forKey: sessionID) }
        await resources.pendingInvites.clear(token: ticket.token)
    }

    private func publishFailure(_ message: String, ticket: SessionAttemptTicket,
                                discardInvitations: Bool) {
        guard accepts(ticket) else { return }
        alertTitle = "Reading session"
        alertMessage = message
        if discardInvitations { invitations = invitations.filter { $0.value.identity != ticket.identity } }
    }

    @MainActor
    private final class SessionAttempt {
        let ticket: SessionAttemptTicket
        private weak var owner: RootWorkflowOwner?
        private let dependencies: AppDependencies
        private let resources: Resources
        private let host: Host
        private let protectedSessionID: String?
        private var response: SharedReadingRedeemResponse?
        private var cleanupAPI: SharedReadingAPI?
        private var runtime: SharedReadingSessionRuntime?

        init(ticket: SessionAttemptTicket, owner: RootWorkflowOwner, dependencies: AppDependencies,
             resources: Resources, host: Host) {
            self.ticket = ticket
            self.owner = owner
            self.dependencies = dependencies
            self.resources = resources
            self.host = host
            protectedSessionID = host.activeRoute(for: ticket.identity.userID)?.sessionID
        }

        private var isCurrent: Bool { owner?.accepts(ticket) == true }

        func run() async {
            guard isCurrent, owner?.onboardingPresented == false else { return }
            var stage = "redeem"
            do {
                let api = try resources.api(.normal(ticket.lease))
                guard api.isBound(to: dependencies.credentialAuthority, context: .normal(ticket.lease)) else {
                    throw CredentialAuthenticationFailure.accountChanged
                }
                let receipt = try await api.redeemWithAccountBoundCleanup(token: ticket.token)
                // Retain both originals BEFORE rejecting stale publication.
                cleanupAPI = receipt.cleanupAPI
                response = receipt.response
                let response = receipt.response
                guard isCurrent else { await compensate(); return }
                if host.isActive(response.sessionId, accountID: ticket.identity.userID) {
                    await owner?.clearPending(ifCurrent: ticket, sessionID: response.sessionId)
                    return
                }
                stage = "prepare"
                let prepared = try await resources.prepareBook(response.book, ticket.identity.userID)
                guard isCurrent else { await compensate(); return }
                guard prepared.contentHash.caseInsensitiveCompare(response.book.contentHash) == .orderedSame else {
                    throw SharedReadingError.from(code: .bookHashMismatch)
                }
                stage = "admission"
                let admission = try await api.markBookReady(sessionId: response.sessionId,
                                                          token: ticket.token, contentHash: prepared.contentHash)
                guard isCurrent else { await compensate(); return }
                let transport = resources.makeTransport()
                let witness = RuntimeWitness()
                let originalLease = ticket.lease
                let identity = ticket.identity
                let authority = dependencies.credentialAuthority
                let token = ticket.token
                let coordinator = SharedReadingSessionCoordinator(
                    transport: transport, localParticipantUserId: originalLease.rawUserID,
                    refreshAdmission: {
                        // A retained existing runtime is the registry's durable
                        // leave-ownership witness across the HTTP suspension.
                        let runtime = try await MainActor.run {
                            guard let runtime = witness.runtime, runtime.canRefreshAdmission,
                                  authority.isCurrent(originalLease) else {
                                throw CredentialAuthenticationFailure.accountChanged
                            }
                            return runtime
                        }
                        let result = try await api.markBookReady(sessionId: response.sessionId,
                                                                 token: token, contentHash: response.book.contentHash)
                        try await MainActor.run {
                            guard runtime.canRefreshAdmission, authority.isCurrent(originalLease) else {
                                throw CredentialAuthenticationFailure.accountChanged
                            }
                        }
                        return result
                    }, refreshBearerToken: { try await api.refreshBearerToken() })
                let runtime = SharedReadingSessionRuntime(
                    api: api, cleanupAPI: receipt.cleanupAPI, coordinator: coordinator, transport: transport,
                    join: SharedReadingJoin(response: response, admission: admission, localBookId: prepared.book.id),
                    localParticipantUserID: originalLease.rawUserID, accountID: ticket.identity.userID,
                    sessionRegistry: resources.registry,
                    invitation: owner?.invitation(for: response.sessionId, ticket: ticket),
                    isAccountCurrent: { [dependencies] in
                        dependencies.cachedUserId == identity.userID
                            && dependencies.accountGeneration == identity.generation
                            && authority.isCurrent(originalLease)
                    })
                self.runtime = runtime
                witness.runtime = runtime
                // Preserve registry admission before the next suspension.
                runtime.retainAdmission()
                stage = "connect"
                try await runtime.connectAndPrepare()
                guard isCurrent else { await compensate(); return }
                guard let context = runtime.readerContext else { throw PresentationFailure.readerUnavailable }
                // Another admitted workflow can open this room during setup.
                // Preserve its membership and retire only this local replacement.
                if host.isActive(response.sessionId, accountID: ticket.identity.userID) {
                    await runtime.closeLocally()
                    await owner?.clearPending(ifCurrent: ticket, sessionID: response.sessionId)
                    return
                }
                guard host.router.presentSharedReader(context, for: ticket.identity.userID) else {
                    throw PresentationFailure.presentationRejected
                }
                await owner?.clearPending(ifCurrent: ticket, sessionID: response.sessionId)
            } catch {
                await compensate()
                guard isCurrent else { return }
                let retryable = (error as? SharedReadingError)?.retryable ?? !(error is PresentationFailure)
                let message: String
                if let error = error as? SharedReadingError {
                    #if DEBUG
                    message = error.debugPresentationMessage(operationStage: stage)
                    #else
                    message = error.presentationMessage
                    #endif
                } else if let error = error as? PresentationFailure {
                    message = error.message
                } else {
                    #if DEBUG
                    message = "Reading session failed during \(stage): \(String(describing: error))"
                    #else
                    message = "Rishi could not open this reading session. Please try again."
                    #endif
                }
                let preserved = protectedSessionID.map { host.isActive($0, accountID: ticket.identity.userID) } == true
                    ? " Your current reading session remains open." : ""
                owner?.publishFailure(message + preserved, ticket: ticket, discardInvitations: !retryable)
                if !retryable { await owner?.clearPending(ifCurrent: ticket, sessionID: response?.sessionId) }
            }
        }

        private func compensate() async {
            guard let sessionID = response?.sessionId else { return }
            guard sessionID != protectedSessionID, !host.isActive(sessionID, accountID: ticket.identity.userID) else {
                await runtime?.closeLocally()
                return
            }
            guard let cleanupAPI else { return }
            let runtime = runtime
            let host = host
            let accountID = ticket.identity.userID
            let cleanup = Task { @MainActor in
                guard !host.isActive(sessionID, accountID: accountID),
                      runtime?.isRegistryDrainRemoteLeaveOwned != true else {
                    await runtime?.closeLocally()
                    return
                }
                do { _ = try await cleanupAPI.leave(sessionId: sessionID, deliberate: true) }
                catch {
                    Log.sharedReading(.sessionLifecycle, level: .error,
                                      context: .init(operation: .leave, outcome: .failed, sessionID: sessionID,
                                                     errorCode: "ABANDONED_MEMBERSHIP_LEAVE_FAILED"))
                }
                await runtime?.closeLocally()
            }
            await cleanup.value
        }

        @MainActor
        private final class RuntimeWitness {
            weak var runtime: SharedReadingSessionRuntime?
        }

        private enum PresentationFailure: Error {
            case readerUnavailable
            case presentationRejected
            var message: String {
                switch self {
                case .readerUnavailable: "The reading session connected, but its book could not be opened."
                case .presentationRejected: "The new reading session could not be opened."
                }
            }
        }
    }
}
