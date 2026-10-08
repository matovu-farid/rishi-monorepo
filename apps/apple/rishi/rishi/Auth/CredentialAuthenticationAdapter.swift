import Foundation

/// One attempt begins before provider/network exchange and follows the app's
/// original account transaction through installation and visible publication.
struct CredentialAuthenticationAttempt: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let ticket: CredentialAttemptTicket
}

@MainActor
final class CredentialAuthenticationAdapter {
    let authority: SessionCredentialAuthority
    private let dependencies: AppDependencies
    private let worker: WorkerClient
    private let consent: any CredentialDataUseConsentStore
    private let installSession: (Session, String?, AccountChangeTransaction) async throws -> CredentialSnapshot
    private let restoreIdentity: (CredentialSnapshot) async throws -> Void
    private let registerPendingDeviceToken: (CredentialSnapshot) async throws -> Void
    private let completeDebugOnboarding: (CredentialSnapshot) async throws -> Void
    private let refreshEntitlement: (CredentialSnapshot) async -> Void
    private var attemptID: UUID?
    private var failedAttempt: (UUID, CredentialTransition)?
    private enum RetirementOwner {
        case rejection(CredentialRejectionContext)
        case transition(CredentialTransition)
    }
    private var retirementOwner: RetirementOwner?

    /// All callbacks are required final-use account effects. The live legacy
    /// constructor does not select this adapter until the atomic cutover.
    init(authority: SessionCredentialAuthority, dependencies: AppDependencies,
         worker: WorkerClient, consent: any CredentialDataUseConsentStore,
         installSession: @escaping (Session, String?, AccountChangeTransaction) async throws -> CredentialSnapshot,
         restoreIdentity: @escaping (CredentialSnapshot) async throws -> Void,
         registerPendingDeviceToken: @escaping (CredentialSnapshot) async throws -> Void,
         completeDebugOnboarding: @escaping (CredentialSnapshot) async throws -> Void,
         refreshEntitlement: @escaping (CredentialSnapshot) async -> Void) throws {
        guard worker.usesCredentialAuthority(authority), dependencies.usesCredentialAuthority(authority) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        self.authority = authority
        self.dependencies = dependencies
        self.worker = worker
        self.consent = consent
        self.installSession = installSession
        self.restoreIdentity = restoreIdentity
        self.registerPendingDeviceToken = registerPendingDeviceToken
        self.completeDebugOnboarding = completeDebugOnboarding
        self.refreshEntitlement = refreshEntitlement
    }

    var workerClient: WorkerClient { worker }
    var appDependencies: AppDependencies { dependencies }

    func exchange<E: WorkerEndpoint>(_ endpoint: E,
                                     attempt: CredentialAuthenticationAttempt) async throws -> E.Response {
        try requireCurrent(attempt)
        let response = try await worker.sendAuthentication(endpoint, expectedCredentialTicket: attempt.ticket)
        try requireCurrent(attempt)
        return response
    }

    func beginAttempt() -> CredentialAuthenticationAttempt {
        let attempt = CredentialAuthenticationAttempt(id: UUID(), ticket: authority.attemptTicket())
        attemptID = attempt.id
        failedAttempt = nil
        retirementOwner = nil
        return attempt
    }

    func isCurrent(_ attempt: CredentialAuthenticationAttempt) -> Bool {
        attemptID == attempt.id && authority.attemptTicket() == attempt.ticket
    }

    func mayReportFailure(for attempt: CredentialAuthenticationAttempt) -> Bool {
        guard attemptID == attempt.id else { return false }
        if isCurrent(attempt) { return true }
        guard let (id, transition) = failedAttempt, id == attempt.id else { return false }
        return authority.isCurrent(transition)
    }

    func completeSignIn(session: Session, refreshToken: String?, user: User,
                        attempt: CredentialAuthenticationAttempt, debugOnboarding: Bool,
                        publish: () -> Void) async throws {
        guard !session.token.isEmpty, !session.userId.isEmpty,
              user.id == DerivedUserID.from(session.userId) else {
            throw CredentialAuthenticationFailure.unavailable(.invalidRecord)
        }
        try requireCurrent(attempt)
        let transaction = try dependencies.beginAccountChange(expectedCredentialTicket: attempt.ticket)
        var installed: CredentialSnapshot?
        do {
            let snapshot = try await installSession(session, refreshToken, transaction)
            installed = snapshot
            try requireCurrent(attempt, snapshot: snapshot)
            guard await consent.bind(to: snapshot.lease) else { throw CredentialAuthenticationFailure.accountChanged }
            try requireCurrent(attempt, snapshot: snapshot)
            if debugOnboarding {
                try await completeDebugOnboarding(snapshot)
                try requireCurrent(attempt, snapshot: snapshot)
                guard await consent.grant(for: snapshot.lease) else { throw CredentialAuthenticationFailure.accountChanged }
                try requireCurrent(attempt, snapshot: snapshot)
            }
            try await registerDeviceIfCurrent(snapshot, attempt: attempt)
            await refreshEntitlement(snapshot)
            try requireCurrent(attempt, snapshot: snapshot)
            guard dependencies.performCredentialMutation(snapshot.lease, mutation: publish) else {
                throw CredentialAuthenticationFailure.accountChanged
            }
        } catch {
            // The failed attempt may retire only its still-owned transition or
            // installation. It never clears/replaces a newer account.
            if let installed, attemptID == attempt.id, authority.isCurrent(installed.lease),
               let rollback = try? dependencies.beginAccountChange(expectedCredentialTicket: installed.ticket) {
                if let transition = rollback.credentialTransition,
                   dependencies.retireCredentialAccount(rollback) != nil {
                    failedAttempt = (attempt.id, transition)
                    retirementOwner = .transition(transition)
                }
            } else if installed == nil, attemptID == attempt.id,
                      dependencies.isCurrentCredentialAccountChange(transaction) {
                if let transition = transaction.credentialTransition,
                   dependencies.retireCredentialAccount(transaction) != nil {
                    failedAttempt = (attempt.id, transition)
                    retirementOwner = .transition(transition)
                }
            }
            throw error
        }
    }

    func restore(into userBox: CurrentUserBox) async {
        if let projection = retirementProjection {
            if case .failed = projection.status { _ = dependencies.retryCredentialRetirement() }
            reconcileRetirement(into: userBox)
            return
        }
        let attempt = beginAttempt()
        let previous = userBox.state
        var captured: CredentialSnapshot?
        if case .signedIn = previous {} else { userBox.state = .loading }
        do {
            let snapshot = try authority.snapshot()
            captured = snapshot
            try requireCurrent(attempt, snapshot: snapshot)
            let user = try await worker.send(UserGetEndpoint(), credentialContext: .normal(snapshot.lease))
            try requireCurrent(attempt, snapshot: snapshot)
            guard user.id == DerivedUserID.from(snapshot.session.userId) else {
                let rejection = try authority.snapshot(for: .normal(snapshot.lease)).rejectionContext
                let admission = dependencies.admitCredentialRejection(.identityMismatch, context: rejection)
                switch admission {
                case .stale: throw CredentialAuthenticationFailure.accountChanged
                case .admitted, .duplicate:
                    throw CredentialAuthenticationFailure.definitiveRejection(.identityMismatch, rejection)
                }
            }
            try await restoreIdentity(snapshot)
            try requireCurrent(attempt, snapshot: snapshot)
            guard await consent.bind(to: snapshot.lease) else { throw CredentialAuthenticationFailure.accountChanged }
            try requireCurrent(attempt, snapshot: snapshot)
            try await registerDeviceIfCurrent(snapshot, attempt: attempt)
            await refreshEntitlement(snapshot)
            try requireCurrent(attempt, snapshot: snapshot)
            _ = dependencies.performCredentialMutation(snapshot.lease) { userBox.signIn(user: user) }
        } catch {
            guard attemptID == attempt.id else { return }
            if case CredentialAuthenticationFailure.definitiveRejection(_, let context) = error {
                publishAdmittedRejection(context, into: userBox)
                return
            }
            guard authority.attemptTicket() == attempt.ticket else { return }
            if case CredentialAuthenticationFailure.accountChanged = error { return }
            if Task.isCancelled || error is CancellationError {
                if let captured {
                    _ = dependencies.performCredentialMutation(captured.lease) { userBox.state = previous }
                } else {
                    userBox.state = previous
                }
                return
            }
            if case CredentialAuthenticationFailure.signedOut = error {
                userBox.signedOutAfterCredentialClear()
                return
            }
            guard let recovery = AuthenticationRecovery.forError(error) else { return }
            if let captured {
                _ = dependencies.performCredentialMutation(captured.lease) {
                    if case .signedIn(let user) = previous,
                       user.id == DerivedUserID.from(captured.session.userId),
                       recovery.kind == .temporarilyUnavailable || recovery.kind == .credentialUnavailable {
                        userBox.state = previous
                    } else {
                        userBox.state = .authenticationRecovery(recovery)
                    }
                }
            } else {
                userBox.state = .authenticationRecovery(recovery)
            }
        }
    }

    /// Used by explicit debug erase/reset. Cleanup keeps the app's actual
    /// owner; this initiating caller must not join its drain.
    func retireCurrentAccount(expected ticket: CredentialAttemptTicket, into userBox: CurrentUserBox) throws {
        guard authority.attemptTicket() == ticket else { throw CredentialAuthenticationFailure.accountChanged }
        _ = beginAttempt()
        let transaction = try dependencies.beginAccountChange(expectedCredentialTicket: ticket)
        guard let transition = transaction.credentialTransition,
              dependencies.retireCredentialAccount(transaction) != nil else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        retirementOwner = .transition(transition)
        reconcileRetirement(into: userBox)
    }

    private func requireCurrent(_ attempt: CredentialAuthenticationAttempt) throws {
        try Task.checkCancellation()
        guard isCurrent(attempt) else { throw CredentialAuthenticationFailure.accountChanged }
    }

    private func requireCurrent(_ attempt: CredentialAuthenticationAttempt, snapshot: CredentialSnapshot) throws {
        try Task.checkCancellation()
        guard attemptID == attempt.id else { throw CredentialAuthenticationFailure.accountChanged }
        _ = try authority.snapshot(for: .normal(snapshot.lease))
    }

    private func registerDeviceIfCurrent(_ snapshot: CredentialSnapshot,
                                         attempt: CredentialAuthenticationAttempt) async throws {
        do { try await registerPendingDeviceToken(snapshot) }
        catch {
            // Registration is best effort, as on the existing live path.
            // Cancellation or a changed owner still prevents subsequent work.
            try requireCurrent(attempt, snapshot: snapshot)
        }
        try requireCurrent(attempt, snapshot: snapshot)
    }

    private func publishAdmittedRejection(_ context: CredentialRejectionContext, into userBox: CurrentUserBox) {
        retirementOwner = .rejection(context)
        reconcileRetirement(into: userBox)
    }

    private var retirementProjection: CredentialRetirementProjection? {
        switch retirementOwner {
        case .rejection(let context): dependencies.credentialRetirementProjection(for: context)
        case .transition(let transition): dependencies.credentialRetirementProjection(for: transition)
        case nil: nil
        }
    }

    /// The central cleanup owner exposes only its exact admitted rejection.
    /// This projection is synchronous and does not join retirement/drain work.
    func reconcileRetirement(into userBox: CurrentUserBox) {
        guard let projection = retirementProjection,
              authority.attemptTicket() == projection.ticket else { return }
        _ = authority.performIfCurrent(projection.transition) {
            switch projection.status {
            case .pending: userBox.state = .authenticationRecovery(.init(kind: .signInRequired))
            case .completed: userBox.signedOutAfterCredentialClear()
            case .failed: userBox.state = .authenticationRecovery(.init(kind: .cleanupIncomplete))
            }
        }
    }
}
