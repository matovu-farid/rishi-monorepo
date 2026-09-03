import SwiftUI
import CoreImage.CIFilterBuiltins

#if canImport(UIKit)
import UIKit
#endif

struct SharedReadingShareComposerView: View {
    let api: SharedReadingAPI
    let bookId: String
    let bookTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var share: SharedReadingCreateResponse?
    @State private var recipients = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false

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
                    }
                }
            }
            .navigationTitle("Start group reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert(
            message ?? "",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message = nil }
        }
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
                let result = try await api.create(bookId: bookId, idempotencyKey: UUID().uuidString)
                await MainActor.run {
                    share = result
                    // The creator is also the initial sharer/controller. Feed
                    // the exact canonical token through the same signed-in,
                    // onboarding, local-download, and admission path used by
                    // invited readers so the creator does not need to open
                    // their own link manually.
                    if let token = URLComponents(url: result.shareURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "token" })?.value {
                        AppRouter.enqueueSessionToken(token)
                    }
                }
            } catch let error as SharedReadingError {
                await MainActor.run { message = error.message; isError = true }
            } catch {
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
