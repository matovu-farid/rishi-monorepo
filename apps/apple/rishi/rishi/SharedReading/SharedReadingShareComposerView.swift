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
                        // The presenting view owns when the creator should
                        // join. It must wait until this sheet is dismissed
                        // before presenting the session sheet.
                        onCreated?(token)
                    }
                }
            } catch let error as SharedReadingError {
                Log.error("sharing.ui.create_link.failed", error: error)
                await MainActor.run { message = error.message; isError = true }
            } catch {
                Log.error("sharing.ui.create_link.failed", error: error)
                await MainActor.run { message = "Rishi could not create the reading link."; isError = true }
            }
        }
    }

    private func sendEmail(share: SharedReadingCreateResponse) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await api.sendEmail(
                    sessionId: share.sessionId,
                    recipients: parsedRecipients,
                    idempotencyKey: UUID().uuidString
                )
                await MainActor.run {
                    message = result.failed == 0
                        ? "Invitations sent."
                        : "The link was created, but \(result.failed) invitation(s) could not be delivered. You can still share the link manually."
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
