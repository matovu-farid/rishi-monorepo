import SwiftUI

/// Account-scoped recovery surface for sessions the user has already joined.
/// It deliberately obtains a fresh admission ticket through `/rejoin`; the
/// original share URL is not required and is never persisted here.
struct ActiveReadingSessionsView: View {
    let api: SharedReadingAPI
    let bookService: SessionBookService
    let userId: UserID
    let sessionRegistry: SharedReadingSessionRegistry

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SharedReadingSessionSummary] = []
    @State private var isLoading = false
    @State private var busySessionId: String?
    @State private var error: SharedReadingError?
    @State private var recoveredSession: SharedReadingRecoveredSession?
    @State private var activeCoordinator: SharedReadingSessionCoordinator?
    @State private var activeTransport: SharedReadingSignalingClient?

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
                    ContentUnavailableView(
                        "No active reading sessions",
                        systemImage: "person.3",
                        description: Text("Sessions you have joined will appear here while they remain open.")
                    )
                } else {
                    List(sessions) { session in
                        Button {
                            join(session)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: session.status == .active ? "book.pages" : "hourglass")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.book.bookId)
                                        .font(.headline)
                                    Text(session.status == .active ? "Reading in progress" : "Waiting for the controller")
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
                    .refreshable { await refresh() }
                }
            }
            .navigationTitle("Active reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await refresh() }
        .sheet(item: $recoveredSession) { recovered in
            if let activeCoordinator, let activeTransport {
                SharedReadingSessionView(
                    api: api,
                    coordinator: activeCoordinator,
                    transport: activeTransport,
                    join: recovered.join,
                    localParticipantUserId: wireUserID,
                    sessionRegistry: sessionRegistry,
                    accountID: userId,
                    requiresAuthoritativeRecovery: true
                )
            } else {
                ProgressView("Preparing reading session…")
            }
        }
        .alert(
            error?.message ?? "",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            ),
            presenting: error
        ) { presentedError in
            if presentedError.retryable {
                Button("Try again") { self.error = nil }
            }
            Button("OK", role: .cancel) { self.error = nil }
        } message: { presentedError in
            Text(presentedError.message)
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            Log.sharedReading(.recovery, context: .init(operation: .active, outcome: .started))
            sessions = try await api.activeSessions().sessions
            Log.sharedReading(.recovery, context: .init(operation: .active, outcome: .completed))
        } catch let sharedError as SharedReadingError {
            Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .active, outcome: .failed, correlationID: sharedError.correlationId, errorCode: sharedError.code.rawValue))
            error = sharedError
        } catch {
            self.error = SharedReadingError.from(code: .serviceUnavailable)
        }
    }

    private func join(_ session: SharedReadingSessionSummary) {
        guard busySessionId == nil else { return }
        busySessionId = session.sessionId
        Task { @MainActor in
            defer { busySessionId = nil }
            do {
                Log.sharedReading(.recovery, context: .init(operation: .rejoin, outcome: .started, sessionID: session.sessionId))
                let preparedBook = try await bookService.prepare(book: session.book, ownerId: userId)
                let importedHash = preparedBook.contentHash
                guard importedHash.caseInsensitiveCompare(session.book.contentHash) == .orderedSame else {
                    throw SharedReadingError.from(code: .bookHashMismatch)
                }
                let admission = try await api.rejoin(sessionId: session.sessionId, contentHash: importedHash)
                guard admission.status != .ended else {
                    throw SharedReadingError.from(code: .sessionEnded)
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
                    summary: session,
                    admission: admission,
                    localBookId: preparedBook.book.id,
                    localContentHash: importedHash
                )
                Log.sharedReading(.recovery, context: .init(operation: .rejoin, outcome: .ready, sessionID: session.sessionId))
                await MainActor.run {
                    activeTransport = transport
                    activeCoordinator = coordinator
                    recoveredSession = recovered
                }
            } catch let sharedError as SharedReadingError {
                Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .rejoin, outcome: .failed, correlationID: sharedError.correlationId, sessionID: session.sessionId, errorCode: sharedError.code.rawValue))
                error = sharedError
            } catch let serviceError as SessionBookService.ServiceError {
                let code: SharedReadingErrorCode = serviceError == .hashMismatch ? .bookHashMismatch : .serviceUnavailable
                error = SharedReadingError.from(code: code)
            } catch {
                self.error = SharedReadingError.from(code: .serviceUnavailable)
            }
        }
    }
}
