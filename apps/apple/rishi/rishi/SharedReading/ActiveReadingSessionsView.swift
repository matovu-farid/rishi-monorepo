import SwiftUI

/// The actual sheet owns its recovery model. Membership compensation outlives
/// this presentation through the model's finite retained join attempt.
struct ActiveReadingSessionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ActiveReadingSessionsModel

    init(
        api: SharedReadingAPI, bookService: SessionBookService, userId: UserID,
        sessionRegistry: SharedReadingSessionRegistry, router: AppRouter,
        credentialSnapshot: CredentialSnapshot, credentialAuthority: SessionCredentialAuthority,
        accountIdentity: LibraryAccountIdentity,
        currentAccountIdentity: @escaping @MainActor @Sendable () -> LibraryAccountIdentity?
    ) throws {
        guard userId == accountIdentity.userID else { throw CredentialAuthenticationFailure.accountChanged }
        _model = State(initialValue: try ActiveReadingSessionsModel(
            api: api, bookService: bookService, sessionRegistry: sessionRegistry, router: router,
            credentialSnapshot: credentialSnapshot, credentialAuthority: credentialAuthority,
            accountIdentity: accountIdentity, currentAccountIdentity: currentAccountIdentity))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.sessions.isEmpty {
                    ProgressView("Loading active sessions…")
                } else if model.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No active reading sessions", systemImage: "person.3")
                    } description: {
                        Text("Sessions you have joined will appear here while they remain open.")
                    } actions: {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await model.refresh(showError: true) }
                        }
                        .disabled(model.isLoading)
                    }
                } else {
                    List(model.sessions) { session in
                        Button {
                            model.join(session)
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
                                if model.busySessionID == session.sessionId {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shared-reading-active-session-\(session.sessionId)")
                        .disabled(model.busySessionID != nil)
                    }
                    .refreshable { await model.refresh(showError: true) }
                }
            }
            .navigationTitle("Active reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.stop()
                        dismiss()
                    }
                }
            }
        }
        .task { await model.observe() }
        .onDisappear { model.stop() }
        .onChange(of: model.isAccountCurrent) { _, current in
            if !current { model.stop() }
        }
        .onChange(of: model.dismissalRequest) { _, request in
            if let request, model.takeDismissal(request) { dismiss() }
        }
        .alert(
            model.error == nil ? "" : "Reading session",
            isPresented: Binding(
                get: { model.error != nil },
                set: {
                    if !$0 {
                        model.clearError()
                    }
                }
            ),
            presenting: model.error
        ) { presentedError in
            if presentedError.retryable {
                Button("Try again") {
                    model.clearError()
                    Task { await model.refresh(showError: true) }
                }
            }
            Button("OK", role: .cancel) {
                model.clearError()
            }
        } message: { presentedError in
            Text(presentedError.presentationMessage)
        }
    }

}
