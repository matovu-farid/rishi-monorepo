import Foundation
import Observation

/// One recovery sheet owns transient presentation; admitted membership stays
/// with the finite join attempt and, after setup, the existing session runtime.
@MainActor
@Observable
final class ActiveReadingSessionsModel {
    enum ErrorOrigin: Equatable { case refresh, join }

    let presentationID = UUID()
    let accountIdentity: LibraryAccountIdentity
    private(set) var sessions: [SharedReadingSessionSummary] = []
    private(set) var isLoading = false
    private(set) var busySessionID: String?
    private(set) var error: SharedReadingError?
    private(set) var errorOrigin: ErrorOrigin?
    private(set) var dismissalRequest: UUID?

    @ObservationIgnored private let api: SharedReadingAPI
    @ObservationIgnored private let registry: SharedReadingSessionRegistry
    @ObservationIgnored private let wireUserID: String
    @ObservationIgnored private let accountIsCurrent: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let prepareBook: @MainActor (SharedReadingBook) async throws -> SessionBookService.PreparedBook
    @ObservationIgnored private let makeTransport: @MainActor () -> any SharedReadingSignalingTransport
    @ObservationIgnored private let presentReader: @MainActor (SharedReadingReaderContext) -> Bool
    @ObservationIgnored private let isActiveReader: @MainActor (String, UUID) -> Bool
    @ObservationIgnored private var refreshToken: UUID? = UUID()
    @ObservationIgnored private var joinAttempt: JoinAttempt?

    convenience init(
        api: SharedReadingAPI, bookService: SessionBookService,
        sessionRegistry: SharedReadingSessionRegistry, router: AppRouter,
        credentialSnapshot: CredentialSnapshot, credentialAuthority: SessionCredentialAuthority,
        accountIdentity: LibraryAccountIdentity,
        currentAccountIdentity: @escaping @MainActor @Sendable () -> LibraryAccountIdentity?
    ) throws {
        try self.init(api: api, sessionRegistry: sessionRegistry,
            credentialSnapshot: credentialSnapshot, credentialAuthority: credentialAuthority,
            accountIdentity: accountIdentity, currentAccountIdentity: currentAccountIdentity,
            prepareBook: { try await bookService.prepare(book: $0, ownerId: accountIdentity.userID) },
            makeTransport: { SharedReadingSignalingClient() },
            presentReader: { router.presentSharedReader($0, for: accountIdentity.userID) },
            isActiveReader: { sessionID, ownerID in
                #if targetEnvironment(macCatalyst)
                let route = router.catalystSharedReaderRoute
                #else
                let route = router.sharedReaderRoute
                #endif
                return route?.accountID == ownerID && route?.sessionID == sessionID
            })
    }

    /// Finite app boundaries for isolated ownership tests. The production
    /// initializer binds these to the concrete book service/runtime/router.
    /// No alternate session lifecycle or credential source is supplied here.
    init(
        api: SharedReadingAPI, sessionRegistry: SharedReadingSessionRegistry,
        credentialSnapshot: CredentialSnapshot, credentialAuthority: SessionCredentialAuthority,
        accountIdentity: LibraryAccountIdentity,
        currentAccountIdentity: @escaping @MainActor @Sendable () -> LibraryAccountIdentity?,
        prepareBook: @escaping @MainActor (SharedReadingBook) async throws -> SessionBookService.PreparedBook,
        makeTransport: @escaping @MainActor () -> any SharedReadingSignalingTransport,
        presentReader: @escaping @MainActor (SharedReadingReaderContext) -> Bool,
        isActiveReader: @escaping @MainActor (String, UUID) -> Bool
    ) throws {
        let lease = credentialSnapshot.lease
        guard accountIdentity.userID == DerivedUserID.from(lease.rawUserID),
              currentAccountIdentity() == accountIdentity,
              api.isBound(to: credentialAuthority, context: .normal(lease)) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        _ = try credentialAuthority.snapshot(for: .normal(lease))
        self.api = api
        self.registry = sessionRegistry
        self.accountIdentity = accountIdentity
        self.wireUserID = lease.rawUserID
        self.accountIsCurrent = {
            credentialAuthority.isCurrent(lease) && currentAccountIdentity() == accountIdentity
        }
        self.prepareBook = prepareBook
        self.makeTransport = makeTransport
        self.presentReader = presentReader
        self.isActiveReader = isActiveReader
    }

    var isAccountCurrent: Bool { accountIsCurrent() }

    func observe() async {
        guard let token = refreshToken, accountIsCurrent() else { stop(); return }
        defer { if refreshToken == token { stop() } }
        await refresh(showError: true)
        while refreshToken == token && !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard refreshToken == token, !Task.isCancelled else { return }
            guard accountIsCurrent() else { stop(); return }
            await refresh(showError: false)
        }
    }

    /// Terminal for this presentation. A reopened sheet creates a new model.
    /// Native rejoin is deliberately not cancelled: its response still owes
    /// compensation even after this presentation's reference has gone away.
    func stop() {
        refreshToken = nil
        joinAttempt?.invalidate()
        joinAttempt = nil
        busySessionID = nil
        sessions = []
        isLoading = false
        clearError()
        dismissalRequest = nil
    }

    func clearError() { error = nil; errorOrigin = nil }

    func takeDismissal(_ request: UUID) -> Bool {
        guard request == presentationID, dismissalRequest == request,
              refreshToken != nil, accountIsCurrent() else { return false }
        dismissalRequest = nil
        return true
    }

    func refresh(showError: Bool) async {
        guard let token = refreshToken, !isLoading, !Task.isCancelled else { return }
        guard accountIsCurrent() else { stop(); return }
        isLoading = true
        defer { if refreshToken == token { isLoading = false } }
        do {
            Log.sharedReading(.recovery, context: .init(operation: .active, outcome: .started))
            let refreshed = try await api.activeSessions().sessions
            guard refreshToken == token, !Task.isCancelled else { return }
            guard accountIsCurrent() else { stop(); return }
            sessions = refreshed
            if errorOrigin == .refresh { clearError() }
            Log.sharedReading(.recovery, context: .init(operation: .active, outcome: .completed))
        } catch {
            guard refreshToken == token, !Task.isCancelled else { return }
            guard accountIsCurrent() else { stop(); return }
            let failure = Self.presentationError(error)
            Log.sharedReading(.errorMapping, level: .error,
                context: .init(operation: .active, outcome: .failed,
                    correlationID: failure.correlationId, errorCode: failure.code.rawValue))
            if showError { self.error = failure; errorOrigin = .refresh }
        }
    }

    /// Returns the existing finite work handle for callers which need to join
    /// completion. Dropping/cancelling UI ownership is done by stop(), not by
    /// cancelling a transport that might have committed server membership.
    @discardableResult
    func join(_ session: SharedReadingSessionSummary) -> Task<Void, Never>? {
        guard refreshToken != nil, busySessionID == nil, accountIsCurrent() else { return nil }
        guard !isActiveReader(session.sessionId, accountIdentity.userID) else {
            dismissalRequest = presentationID
            return nil
        }
        let attempt = JoinAttempt(model: self, session: session)
        joinAttempt = attempt
        busySessionID = session.sessionId
        return attempt.start()
    }

    private func accepts(_ attempt: JoinAttempt) -> Bool {
        refreshToken != nil && joinAttempt?.id == attempt.id
            && attempt.presentationID == presentationID && accountIsCurrent()
    }

    private func finish(_ attempt: JoinAttempt) {
        guard joinAttempt === attempt else { return }
        joinAttempt = nil
        busySessionID = nil
    }

    private func dismiss(for attempt: JoinAttempt) {
        guard accepts(attempt) else { return }
        dismissalRequest = presentationID
    }

    private func report(_ failure: Error, for attempt: JoinAttempt) {
        guard accepts(attempt) else { return }
        let mapped = Self.presentationError(failure)
        Log.sharedReading(.errorMapping, level: .error,
            context: .init(operation: .rejoin, outcome: .failed,
                correlationID: mapped.correlationId, sessionID: attempt.session.sessionId,
                errorCode: mapped.code.rawValue))
        error = mapped
        errorOrigin = .join
    }

    private static func presentationError(_ error: Error) -> SharedReadingError {
        if let error = error as? SharedReadingError { return error }
        if let error = error as? CredentialAuthenticationFailure {
            return .from(code: error == .accountChanged ? .accountChanged : .authRequired)
        }
        if let error = error as? SessionBookService.ServiceError {
            switch error {
            case .hashMismatch: return .from(code: .bookHashMismatch)
            case .accountChanged: return .from(code: .accountChanged)
            default: return .from(code: .serviceUnavailable)
            }
        }
        return .from(code: .serviceUnavailable)
    }

    /// Idle callback is weak; an admitted reconnect locally retains the real
    /// runtime before awaiting its receipt, preserving its durable leave claim.
    @MainActor
    private final class RuntimeReference {
        weak var runtime: SharedReadingSessionRuntime?
    }

    @MainActor
    private final class JoinAttempt {
        let id = UUID()
        let presentationID: UUID
        let accountIdentity: LibraryAccountIdentity
        let session: SharedReadingSessionSummary
        private weak var model: ActiveReadingSessionsModel?
        private let api: SharedReadingAPI
        private let registry: SharedReadingSessionRegistry
        private let wireUserID: String
        private let accountIsCurrent: @MainActor @Sendable () -> Bool
        private let prepareBook: @MainActor (SharedReadingBook) async throws -> SessionBookService.PreparedBook
        private let makeTransport: @MainActor () -> any SharedReadingSignalingTransport
        private let presentReader: @MainActor (SharedReadingReaderContext) -> Bool
        private let isActiveReader: @MainActor (String, UUID) -> Bool
        private var valid = true
        private var task: Task<Void, Never>?
        private var receipt: (admission: SharedReadingAdmission, cleanupAPI: SharedReadingAPI)?
        private var runtime: SharedReadingSessionRuntime?
        private var cleanupTask: Task<Void, Never>?

        init(model: ActiveReadingSessionsModel, session: SharedReadingSessionSummary) {
            self.model = model
            self.presentationID = model.presentationID
            self.accountIdentity = model.accountIdentity
            self.session = session
            self.api = model.api
            self.registry = model.registry
            self.wireUserID = model.wireUserID
            self.accountIsCurrent = model.accountIsCurrent
            self.prepareBook = model.prepareBook
            self.makeTransport = model.makeTransport
            self.presentReader = model.presentReader
            self.isActiveReader = model.isActiveReader
        }

        func invalidate() { valid = false }

        func start() -> Task<Void, Never> {
            let work = Task { @MainActor [self] in await run() }
            task = work
            return work
        }

        private var isCurrent: Bool {
            valid && !Task.isCancelled && accountIsCurrent() && model?.accepts(self) == true
        }

        private var isAlreadyPresented: Bool {
            isActiveReader(session.sessionId, accountIdentity.userID)
        }

        private func run() async {
            defer {
                model?.finish(self)
                receipt = nil
                runtime = nil
                cleanupTask = nil
                task = nil
            }
            do {
                guard isCurrent else { return }
                guard !isAlreadyPresented else { model?.dismiss(for: self); return }
                Log.sharedReading(.recovery,
                    context: .init(operation: .rejoin, outcome: .started, sessionID: session.sessionId))
                let prepared = try await prepareBook(session.book)
                guard isCurrent else { return }
                guard !isAlreadyPresented else { model?.dismiss(for: self); return }
                guard prepared.contentHash.caseInsensitiveCompare(session.book.contentHash) == .orderedSame else {
                    throw SharedReadingError.from(code: .bookHashMismatch)
                }
                // Preserve the successful response and actual request bearer
                // BEFORE checking presentation/account currentness.
                receipt = try await api.rejoinWithAccountBoundCleanup(
                    sessionId: session.sessionId, contentHash: prepared.contentHash)
                guard let receipt else { return }
                guard isCurrent else { await releaseRawAdmission(receipt.cleanupAPI); return }
                guard !isAlreadyPresented else { model?.dismiss(for: self); return }
                let transport = makeTransport()
                let originalAPI = api
                let summary = session
                let activeReader = isActiveReader
                let ownerID = accountIdentity.userID
                let runtimeReference = RuntimeReference()
                let coordinator = SharedReadingSessionCoordinator(
                    transport: transport, localParticipantUserId: wireUserID,
                    refreshAdmission: {
                        try Task.checkCancellation()
                        // Hold the existing runtime's durable leave witness
                        // across HTTP. No UI lifetime or registry-presence
                        // inference owns this successfully committed receipt.
                        let refresh = Task { @MainActor in
                            guard let liveRuntime = runtimeReference.runtime,
                                  liveRuntime.canRefreshAdmission else {
                                throw SharedReadingError.from(code: .accountChanged)
                            }
                            let refreshed = try await originalAPI.rejoinWithAccountBoundCleanup(
                                sessionId: summary.sessionId, contentHash: summary.book.contentHash)
                            guard liveRuntime.canRefreshAdmission else {
                                if !liveRuntime.isRegistryDrainRemoteLeaveOwned,
                                   !activeReader(summary.sessionId, ownerID) {
                                    _ = try? await refreshed.cleanupAPI.leave(
                                        sessionId: summary.sessionId, deliberate: true)
                                }
                                throw SharedReadingError.from(code: .accountChanged)
                            }
                            return refreshed.admission
                        }
                        return try await refresh.value
                    },
                    refreshBearerToken: { try await originalAPI.refreshBearerToken() })
                let recovered = SharedReadingRecoveredSession(summary: session, admission: receipt.admission,
                    localBookId: prepared.book.id, localContentHash: prepared.contentHash)
                let replacement = SharedReadingSessionRuntime(
                    api: api, cleanupAPI: receipt.cleanupAPI, coordinator: coordinator, transport: transport,
                    join: recovered.join, localParticipantUserID: wireUserID,
                    accountID: ownerID, sessionRegistry: registry,
                    requiresAuthoritativeRecovery: true, isAccountCurrent: accountIsCurrent)
                runtime = replacement
                runtimeReference.runtime = replacement
                replacement.retainAdmission()
                guard isCurrent else { await cleanUp(replacement); return }
                guard receipt.admission.status != .ended else {
                    await cleanUp(replacement)
                    throw SharedReadingError.from(code: .sessionEnded)
                }
                do {
                    try await replacement.connectAndPrepare()
                    let context = replacement.readerContext
                    guard isCurrent, let context, context.runtime === replacement else {
                        await cleanUp(replacement)
                        return
                    }
                    guard !isAlreadyPresented else {
                        await replacement.closeLocally()
                        model?.dismiss(for: self)
                        return
                    }
                    guard presentReader(context) else { await cleanUp(replacement); return }
                    model?.dismiss(for: self)
                } catch {
                    await cleanUp(replacement)
                    guard isCurrent else { return }
                    throw error
                }
            } catch {
                guard isCurrent else { return }
                model?.report(error, for: self)
            }
        }

        private func cleanUp(_ runtime: SharedReadingSessionRuntime) async {
            if isAlreadyPresented { await runtime.closeLocally(); return }
            if accountIsCurrent() || !runtime.isRegistryDrainRemoteLeaveOwned {
                await runtime.leaveAndClose()
            }
        }

        private func releaseRawAdmission(_ cleanupAPI: SharedReadingAPI) async {
            let summary = session
            let ownerID = accountIdentity.userID
            let activeReader = isActiveReader
            let cleanup = Task { @MainActor in
                guard !activeReader(summary.sessionId, ownerID) else { return }
                _ = try? await cleanupAPI.leave(sessionId: summary.sessionId, deliberate: true)
            }
            cleanupTask = cleanup
            await cleanup.value
            cleanupTask = nil
        }
    }
}
