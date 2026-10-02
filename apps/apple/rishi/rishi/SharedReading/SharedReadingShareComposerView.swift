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
    }
}

struct SharedReadingShareComposerView: View {
    let api: SharedReadingAPI
    let bookId: String
    let bookTitle: String
    let repairBook: (@Sendable () async -> Bool)?
    let onCreated: (@MainActor (SharedReadingInvitation) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false
    @State private var hasStartedCreation = false
    @State private var message: String?

    init(
        api: SharedReadingAPI,
        bookId: String,
        bookTitle: String,
        repairBook: (@Sendable () async -> Bool)? = nil,
        onCreated: (@MainActor (SharedReadingInvitation) -> Void)? = nil
    ) {
        self.api = api
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.repairBook = repairBook
        self.onCreated = onCreated
    }

    var body: some View {
        Group {
            if let message {
                VStack(spacing: 20) {
                    ContentUnavailableView(
                        "Couldn’t start group reading",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    HStack {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Try Again") { retryCreation() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .accessibilityIdentifier("shared-reading-error")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting group reading…")
                        .font(.headline)
                    Text(bookTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("shared-reading-starting")
            }
        }
        .interactiveDismissDisabled(isBusy)
        .task { createLinkIfNeeded() }
    }

    private func createLinkIfNeeded() {
        guard !hasStartedCreation else { return }
        hasStartedCreation = true
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
                await MainActor.run { message = error.presentationMessage }
            } catch {
                Log.sharedReading(.errorMapping, level: .error, context: .init(operation: .create, outcome: .failed, errorCode: "UNKNOWN"))
#if DEBUG
                await MainActor.run { message = "Couldn’t start group reading: \(String(describing: error))" }
#else
                await MainActor.run { message = "Rishi could not create the reading link." }
#endif
            }
        }
    }

    private func retryCreation() {
        guard !isBusy else { return }
        message = nil
        hasStartedCreation = false
        createLinkIfNeeded()
    }

    private func enqueueCreatorAndDismiss(for share: SharedReadingCreateResponse) {
        guard case .sessionRedeem(let token) = DeepLinkRouter().route(share.shareURL),
            !token.isEmpty
        else {
            message = "Rishi could not open this reading session."
            return
        }

        // The parent owns the sheet's onDismiss callback and starts the reader
        // only after that transition has finished.
        let invitation = SharedReadingInvitation(
            sessionID: share.sessionId,
            shareURL: share.shareURL
        )
        Log.sharedReading(.sessionLifecycle, context: .init(operation: .create, outcome: .ready, sessionID: share.sessionId))
        onCreated?(invitation)
        dismiss()
    }
}
