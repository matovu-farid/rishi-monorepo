import SwiftUI

enum SharedReadingSessionCreation {
    static func create<Response: Sendable>(
        operation: @escaping @Sendable () async throws -> Response,
        repair: (@Sendable () async -> Bool)?
    ) async throws -> Response {
        do {
            return try await operation()
        } catch let error as SharedReadingError where shouldRepair(error) {
            guard let repair, await repair() else { throw error }
            return try await operation()
        }
    }

    private static func shouldRepair(_ error: SharedReadingError) -> Bool {
        error.code == .bookNotReady
            || (error.code == .sessionLinkInvalid && error.message.localizedCaseInsensitiveContains("book not found"))
    }
}

struct SharedReadingShareComposerView: View {
    let api: SharedReadingAPI
    let bookId: String
    let bookTitle: String
    let repairBook: (@Sendable () async -> Bool)?
    let onCreated: (@MainActor (String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false
    @State private var creatorTokenToEnqueue: String?

    init(
        api: SharedReadingAPI,
        bookId: String,
        bookTitle: String,
        repairBook: (@Sendable () async -> Bool)? = nil,
        onCreated: (@MainActor (String) -> Void)? = nil
    ) {
        self.api = api
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.repairBook = repairBook
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(bookTitle)
                        .font(.headline)
                    Text("The book is shared immediately. Readers must sign in, finish onboarding, and import the verified book before joining the room.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Create reading link") { createLink() }
                        .disabled(isBusy)
                        .accessibilityIdentifier("shared-reading-create-link")
                }

                #if DEBUG
                if let message {
                    Section("Development diagnostics") {
                        Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(isError ? .red : .secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("shared-reading-error")
                    }
                }
                #endif
            }
            .navigationTitle("Start group reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onDisappear {
            enqueueCreatorAfterDismiss()
        }
        #if !DEBUG
        .alert(
            message ?? "",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message = nil }
        }
        #endif
    }

    private func createLink() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let idempotencyKey = UUID().uuidString
                let result = try await SharedReadingSessionCreation.create(
                    operation: { try await api.create(bookId: bookId, idempotencyKey: idempotencyKey) },
                    repair: repairBook
                )
                await MainActor.run {
                    enqueueCreatorAndDismiss(for: result)
                }
            } catch let error as SharedReadingError {
                Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .create, outcome: .failed, correlationID: error.correlationId, errorCode: error.code.rawValue))
                await MainActor.run { message = error.message; isError = true }
            } catch {
                Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .create, outcome: .failed, errorCode: "UNKNOWN"))
                await MainActor.run { message = "Rishi could not create the reading link."; isError = true }
            }
        }
    }

    private func enqueueCreatorAfterDismiss() {
        guard let creatorTokenToEnqueue else { return }
        self.creatorTokenToEnqueue = nil
        onCreated?(creatorTokenToEnqueue)
    }

    private func enqueueCreatorAndDismiss(for share: SharedReadingCreateResponse) {
        guard case .sessionRedeem(let token) = DeepLinkRouter().route(share.shareURL),
            !token.isEmpty
        else {
            message = "Rishi could not open this reading session."
            isError = true
            return
        }

        // RootView owns the session sheet. Retaining the token until this
        // composer disappears prevents two sheet presentations from racing.
        creatorTokenToEnqueue = token
        dismiss()
    }
}
