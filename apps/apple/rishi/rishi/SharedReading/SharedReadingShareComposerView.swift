import SwiftUI
import CoreImage.CIFilterBuiltins

#if canImport(UIKit)
import UIKit
#endif

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
    @State private var share: SharedReadingCreateResponse?
    @State private var recipients = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false
    @State private var emailDelivery: SharedReadingEmailResponse?
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

                if let share {
                    Section("Share this exact link") {
                        ShareLink(item: share.shareURL) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityHint("Shares the same link represented by the QR code and email invitations")

                        Text(share.shareURL.absoluteString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)

                        #if canImport(UIKit)
                        if let image = QRCodeImage.make(from: share.shareURL.absoluteString) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("QR code for the shared reading link")
                        }
                        #endif
                    }

                    Section("Email (optional)") {
                        TextField("Email addresses, separated by commas", text: $recipients, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Send invitations") { sendEmail(share: share) }
                            .disabled(isBusy || parsedRecipients.isEmpty)
                    }

                    if let emailDelivery {
                        Section("Email delivery") {
                            Text("Sent \(emailDelivery.sent) of \(emailDelivery.attempted) invitation\(emailDelivery.attempted == 1 ? "" : "s").")

                            ForEach(emailDelivery.results) { delivery in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(delivery.email)
                                    Text(deliveryMessage(for: delivery))
                                        .font(.footnote)
                                        .foregroundStyle(delivery.status == .failed ? .red : .secondary)
                                }
                            }

                            if emailDelivery.retryable, emailDelivery.action == "retry" {
                                Text("Some invitations could not be delivered. You can retry them or share the link another way.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Button("Retry failed invitations") {
                                    retryFailedEmails(share: share, delivery: emailDelivery)
                                }
                                .disabled(isBusy || failedRecipients(in: emailDelivery).isEmpty)
                            } else {
                                Text(deliveryActionMessage(for: emailDelivery))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Support ID: \(emailDelivery.correlationId)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } else {
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
            }
            .navigationTitle("Start group reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

    private var parsedRecipients: [String] {
        recipients
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("@") && $0.count <= 320 }
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
                    share = result
                    if let token = URLComponents(url: result.shareURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "token" })?.value {
                        // This sheet must finish dismissing before RootView
                        // presents the session sheet. Keep the owner token
                        // locally and hand it off from this composer's own
                        // dismissal lifecycle, without a timing delay.
                        creatorTokenToEnqueue = token
                        dismiss()
                    }
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

    private func sendEmail(share: SharedReadingCreateResponse) {
        sendEmail(share: share, recipients: parsedRecipients)
    }

    private func enqueueCreatorAfterDismiss() {
        guard let creatorTokenToEnqueue else { return }
        self.creatorTokenToEnqueue = nil
        onCreated?(creatorTokenToEnqueue)
    }

    private func retryFailedEmails(share: SharedReadingCreateResponse, delivery: SharedReadingEmailResponse) {
        sendEmail(share: share, recipients: failedRecipients(in: delivery))
    }

    private func failedRecipients(in delivery: SharedReadingEmailResponse) -> [String] {
        delivery.results
            .filter { $0.status == .failed }
            .map(\.email)
    }

    private func deliveryMessage(for delivery: SharedReadingEmailResponse.Delivery) -> String {
        switch delivery.status {
        case .sent:
            return "Sent"
        case .alreadySent:
            return "Already sent"
        case .failed:
            return "Could not be delivered"
        }
    }

    private func deliveryActionMessage(for delivery: SharedReadingEmailResponse) -> String {
        delivery.retryable
            ? "Action: \(delivery.action)"
            : "Action: no further delivery action is needed."
    }

    private func sendEmail(share: SharedReadingCreateResponse, recipients: [String]) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await api.sendEmail(
                    sessionId: share.sessionId,
                    recipients: recipients,
                    idempotencyKey: UUID().uuidString
                )
                await MainActor.run {
                    emailDelivery = result
                    message = result.failed == 0
                        ? "Invitations sent."
                        : "The link was created, but \(result.failed) invitation(s) could not be delivered. You can retry those invitations or share the link manually."
                    isError = result.failed > 0
                }
            } catch let error as SharedReadingError {
                await MainActor.run { message = error.message; isError = true }
            } catch {
                await MainActor.run { message = "The link is ready, but email delivery failed."; isError = true }
            }
        }
    }
}

#if canImport(UIKit)
private enum QRCodeImage {
    static func make(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, Int(320 / max(output.extent.width, output.extent.height)))
        let transformed = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return UIImage(ciImage: transformed)
    }
}
#endif
