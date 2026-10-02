import SwiftUI

/// Account-scoped recovery surface for sessions the user has already joined.
/// It deliberately obtains a fresh admission ticket through `/rejoin`; the
/// original share URL is not required and is never persisted here.
struct ActiveReadingSessionsView: View {
    private struct JoinAttempt: Equatable {
        let id = UUID()
        let accountID: UserID
        let accountGeneration: UInt64
        let sessionID: String
    }

    let api: SharedReadingAPI
    let bookService: SessionBookService
    let userId: UserID
    let sessionRegistry: SharedReadingSessionRegistry
    let router: AppRouter

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SharedReadingSessionSummary] = []
    @State private var isLoading = false
    @State private var busySessionId: String?
    @State private var error: SharedReadingError?
    @State private var joinTask: Task<Void, Never>?
    @State private var joinAttempt: JoinAttempt?
    @State private var refreshToken: UUID?
    @State private var observedAccountGeneration: UInt64?

    private var wireUserID: String {
        if let persisted = try? Keychain.load(.userId), !persisted.isEmpty {
            return persisted
        }
        return userId.uuidString
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && sessions.isEmpty {
                    ProgressView("Loading active sessions…")
                } else if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No active reading sessions", systemImage: "person.3")
                    } description: {
                        Text("Sessions you have joined will appear here while they remain open.")
                    } actions: {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await refresh(showError: true) }
                        }
                        .disabled(isLoading)
                    }
                } else {
                    List(sessions) { session in
                        Button {
                            join(session)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "book.pages")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.book.bookId)
                                        .font(.headline)
                                    Text(session.status == .active ? "Reading in progress" : "Reading session available")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busySessionId == session.sessionId {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shared-reading-active-session-\(session.sessionId)")
                        .disabled(busySessionId != nil)
                    }
                    .refreshable { await refresh(showError: true) }
                }
            }
            .navigationTitle("Active reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        cancelJoin()
                        dismiss()
                    }
                }
            }
        }
        .task { await observeActiveSessions() }
        .onDisappear {
            stopRefreshing()
            cancelJoin()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .rishiAccountTransitionStarted,
            object: AppDependencies.shared
        )) { _ in
            stopRefreshing()
            cancelJoin()
        }
        .alert(
            error == nil ? "" : "Reading session",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            ),
            presenting: error
        ) { presentedError in
            if presentedError.retryable {
                Button("Try again") {
                    self.error = nil
                    Task { await refresh(showError: true) }
                }
            }
            Button("OK", role: .cancel) { self.error = nil }
        } message: { presentedError in
            Text(presentedError.presentationMessage)
        }
    }

    @MainActor
    private func observeActiveSessions() async {
        let token = UUID()
        let generation = AppDependencies.shared.accountGeneration
        refreshToken = token
        observedAccountGeneration = generation
        guard AppDependencies.shared.cachedUserId == userId else {
            stopRefreshing(if: token)
            return
        }

        await refresh(showError: true)
        while refreshToken == token && !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard refreshToken == token && !Task.isCancelled else { return }
            guard AppDependencies.shared.cachedUserId == userId,
                  AppDependencies.shared.accountGeneration == generation else {
                stopRefreshing(if: token)
                return
            }
            await refresh(showError: false)
        }
    }

    @MainActor
    private func stopRefreshing(if token: UUID? = nil) {
        guard token == nil || refreshToken == token else { return }
        refreshToken = nil
        observedAccountGeneration = nil
        sessions = []
        error = nil
        isLoading = false
    }

    @MainActor
    private func refresh(showError: Bool) async {
        let accountID = userId
        let generation = AppDependencies.shared.accountGeneration
        guard let token = refreshToken,
              !isLoading, !Task.isCancelled else { return }
        guard AppDependencies.shared.cachedUserId == accountID,
              observedAccountGeneration == generation else {
            stopRefreshing(if: token)
            return
        }
        isLoading = true
        defer {
            if refreshToken == token { isLoading = false }
        }
        do {
            Log.sharedReading(.recovery, context: .init(operation: .active, outcome: .started))
            let refreshedSessions = try await api.activeSessions().sessions
            guard refreshToken == token, !Task.isCancelled else { return }
            guard AppDependencies.shared.cachedUserId == accountID,
                  AppDependencies.shared.accountGeneration == generation else {
                stopRefreshing(if: token)
                return
            }
            sessions = refreshedSessions
            if showError { error = nil }
            Log.sharedReading(.recovery, context: .init(operation: .active, outcome: .completed))
        } catch let sharedError as SharedReadingError {
            guard refreshToken == token, !Task.isCancelled else { return }
            guard AppDependencies.shared.cachedUserId == accountID,
                  AppDependencies.shared.accountGeneration == generation else {
                stopRefreshing(if: token)
                return
            }
            Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .active, outcome: .failed, correlationID: sharedError.correlationId, errorCode: sharedError.code.rawValue))
            if showError { error = sharedError }
        } catch {
            guard refreshToken == token, !Task.isCancelled else { return }
            guard AppDependencies.shared.cachedUserId == accountID,
                  AppDependencies.shared.accountGeneration == generation else {
                stopRefreshing(if: token)
                return
            }
            if showError { self.error = SharedReadingError.from(code: .serviceUnavailable) }
        }
    }

    private func join(_ session: SharedReadingSessionSummary) {
        guard busySessionId == nil else { return }
        guard AppDependencies.shared.cachedUserId == userId else { return }
        guard !isActiveSharedReader(sessionID: session.sessionId, accountID: userId) else {
            dismiss()
            return
        }
        let attempt = JoinAttempt(
            accountID: userId,
            accountGeneration: AppDependencies.shared.accountGeneration,
            sessionID: session.sessionId
        )
        busySessionId = session.sessionId
        joinAttempt = attempt
        joinTask = Task { @MainActor in await performJoin(session, attempt: attempt) }
    }

    @MainActor
    private func cancelJoin() {
        // Do not cancel an in-flight /rejoin: the server may have committed
        // the membership before URLSession receives its response. Mark the
        // attempt stale and let its account-bound cleanup run afterward.
        joinTask = nil
        joinAttempt = nil
        busySessionId = nil
    }

    @MainActor
    private func isCurrent(_ attempt: JoinAttempt) -> Bool {
        !Task.isCancelled
            && joinAttempt == attempt
            && AppDependencies.shared.cachedUserId == attempt.accountID
            && AppDependencies.shared.accountGeneration == attempt.accountGeneration
    }

    @MainActor
    private func performJoin(_ session: SharedReadingSessionSummary, attempt: JoinAttempt) async {
        defer {
            if joinAttempt == attempt {
                joinTask = nil
                joinAttempt = nil
                busySessionId = nil
            }
        }

        do {
            guard !isActiveSharedReader(sessionID: session.sessionId, accountID: attempt.accountID) else {
                dismiss()
                return
            }
            Log.sharedReading(.recovery, context: .init(operation: .rejoin, outcome: .started, sessionID: session.sessionId))
            let preparedBook = try await bookService.prepare(book: session.book, ownerId: userId)
            guard isCurrent(attempt) else { return }
            guard !isActiveSharedReader(sessionID: session.sessionId, accountID: attempt.accountID) else {
                dismiss()
                return
            }
            let importedHash = preparedBook.contentHash
            guard importedHash.caseInsensitiveCompare(session.book.contentHash) == .orderedSame else {
                throw SharedReadingError.from(code: .bookHashMismatch)
            }
            let rejoin = try await api.rejoinWithAccountBoundCleanup(
                sessionId: session.sessionId,
                contentHash: importedHash
            )
            let admission = rejoin.admission
            guard isCurrent(attempt) else {
                await releaseAbandonedRejoin(
                    sessionID: session.sessionId,
                    accountID: attempt.accountID,
                    cleanupAPI: rejoin.cleanupAPI
                )
                return
            }
            // Rejoining an already-displayed room must never create a second
            // runtime or send /leave: both runtimes represent the same member.
            guard !isActiveSharedReader(sessionID: session.sessionId, accountID: attempt.accountID) else {
                dismiss()
                return
            }
            let transport = SharedReadingSignalingClient()
            let refreshAdmission: @Sendable () async throws -> SharedReadingAdmission = {
                try await api.rejoin(sessionId: session.sessionId, contentHash: session.book.contentHash)
            }
            let coordinator = SharedReadingSessionCoordinator(
                transport: transport,
                localParticipantUserId: wireUserID,
                refreshAdmission: refreshAdmission,
                refreshBearerToken: { try await api.refreshBearerToken() }
            )
            let recovered = SharedReadingRecoveredSession(
                summary: session, admission: admission,
                localBookId: preparedBook.book.id, localContentHash: importedHash
            )
            Log.sharedReading(.recovery, context: .init(operation: .rejoin, outcome: .ready, sessionID: session.sessionId))
            let runtime = SharedReadingSessionRuntime(
                api: api, cleanupAPI: rejoin.cleanupAPI,
                coordinator: coordinator, transport: transport, join: recovered.join,
                localParticipantUserID: wireUserID, accountID: userId, sessionRegistry: sessionRegistry,
                requiresAuthoritativeRecovery: true,
                isAccountCurrent: {
                    AppDependencies.shared.cachedUserId == attempt.accountID
                        && AppDependencies.shared.accountGeneration == attempt.accountGeneration
                }
            )
            // `/rejoin` has admitted us at this point. Retain that admission
            // before checking cancellation so a concurrent account transition
            // can drain it; an ordinary user cancellation leaves it below.
            runtime.retainAdmission()
            guard isCurrent(attempt) else {
                await cleanUpAbandonedAdmission(runtime, attempt: attempt)
                return
            }
            guard admission.status != .ended else {
                await cleanUpAbandonedAdmission(runtime, attempt: attempt)
                throw SharedReadingError.from(code: .sessionEnded)
            }
            do {
                try await runtime.connectAndPrepare()
                // A cancelled recovery join may complete after the network
                // layer returns. It has already rejoined server-side, so it
                // must leave remotely as well as closing local resources.
                guard isCurrent(attempt), let context = runtime.readerContext else {
                    await cleanUpAbandonedAdmission(runtime, attempt: attempt)
                    return
                }
                guard !isActiveSharedReader(sessionID: session.sessionId, accountID: attempt.accountID) else {
                    await runtime.closeLocally()
                    dismiss()
                    return
                }
                guard router.presentSharedReader(context, for: userId) else {
                    await cleanUpAbandonedAdmission(runtime, attempt: attempt)
                    return
                }
                dismiss()
            } catch {
                // `connectAndPrepare` closes its local resources when setup
                // fails. If cancellation raced that failure, complete the
                // server leave unless the account registry already owns it.
                if isCurrent(attempt) {
                    // Local setup failed after `/rejoin` admitted this account.
                    // Release the server-side seat before surfacing the error.
                    await cleanUpAbandonedAdmission(runtime, attempt: attempt)
                    throw error
                }
                await cleanUpAbandonedAdmission(runtime, attempt: attempt)
                return
            }
        } catch let sharedError as SharedReadingError {
            guard isCurrent(attempt) else { return }
            Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .rejoin, outcome: .failed, correlationID: sharedError.correlationId, sessionID: session.sessionId, errorCode: sharedError.code.rawValue))
            error = sharedError
        } catch let serviceError as SessionBookService.ServiceError {
            guard isCurrent(attempt) else { return }
            let code: SharedReadingErrorCode = serviceError == .hashMismatch ? .bookHashMismatch : .serviceUnavailable
            error = SharedReadingError.from(code: code)
        } catch {
            guard isCurrent(attempt) else { return }
            self.error = SharedReadingError.from(code: .serviceUnavailable)
        }
    }

    /// An ordinary cancellation has no registry drain, so it must leave its
    /// server admission itself. A transition claims remote-leave ownership
    /// before it closes local runtime resources; that durable claim survives
    /// unregistering and keeps this recovery cleanup from racing the registry.
    @MainActor
    private func cleanUpAbandonedAdmission(
        _ runtime: SharedReadingSessionRuntime,
        attempt: JoinAttempt
    ) async {
        if isActiveSharedReader(sessionID: runtime.join.response.sessionId, accountID: attempt.accountID) {
            await runtime.closeLocally()
            return
        }
        let accountIsStillCurrent = AppDependencies.shared.cachedUserId == attempt.accountID
            && AppDependencies.shared.accountGeneration == attempt.accountGeneration
        if accountIsStillCurrent || !runtime.isRegistryDrainRemoteLeaveOwned {
            await runtime.leaveAndClose()
        }
    }

    @MainActor
    private func releaseAbandonedRejoin(
        sessionID: String,
        accountID: UUID,
        cleanupAPI: SharedReadingAPI
    ) async {
        let cleanup = Task { @MainActor in
            guard !isActiveSharedReader(sessionID: sessionID, accountID: accountID) else { return }
            _ = try? await cleanupAPI.leave(sessionId: sessionID, deliberate: true)
        }
        await cleanup.value
    }

    @MainActor
    private func isActiveSharedReader(sessionID: String, accountID: UUID) -> Bool {
        #if targetEnvironment(macCatalyst)
        let route = router.catalystSharedReaderRoute
        #else
        let route = router.sharedReaderRoute
        #endif
        return route?.accountID == accountID && route?.sessionID == sessionID
    }
}
