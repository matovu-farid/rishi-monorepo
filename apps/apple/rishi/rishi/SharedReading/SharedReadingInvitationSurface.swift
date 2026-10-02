import SwiftUI

#if canImport(UIKit)
import CoreImage.CIFilterBuiltins
import UIKit
#endif

struct SharedReadingInvitationSurface: View {
    let api: SharedReadingAPI
    let invitation: SharedReadingInvitation

    @Environment(\.dismiss) private var dismiss
    @State private var recipients = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false
    @State private var emailDelivery: SharedReadingEmailResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Invite readers")
                .font(.headline)

            ShareLink(item: invitation.shareURL) {
                Label("Share link", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Shares the reading-room invitation link")

            Text(invitation.shareURL.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)

            #if canImport(UIKit)
            if let image = SharedReadingInvitationQRCode.make(from: invitation.shareURL.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR code for the shared reading link")
            }
            #endif

            TextField("Email addresses, separated by commas", text: $recipients, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Send invitations") { sendEmail(recipients: parsedRecipients) }
                .disabled(isBusy || parsedRecipients.isEmpty)

            if let emailDelivery {
                Text("Sent \(emailDelivery.sent) of \(emailDelivery.attempted) invitation\(emailDelivery.attempted == 1 ? "" : "s").")
                    .font(.footnote)

                ForEach(emailDelivery.results) { delivery in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(delivery.email)
                        Text(deliveryMessage(for: delivery))
                            .font(.footnote)
                            .foregroundStyle(delivery.status == .failed ? .red : .secondary)
                    }
                }

                if emailDelivery.retryable, emailDelivery.action == "retry" {
                    Button("Retry failed invitations") {
                        sendEmail(recipients: failedRecipients(in: emailDelivery))
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

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(isError ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .disabled(isBusy)
            }
        }
    }

    private var parsedRecipients: [String] {
        recipients
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("@") && $0.count <= 320 }
    }

    private func sendEmail(recipients: [String]) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await api.sendEmail(
                    sessionId: invitation.sessionID,
                    recipients: recipients,
                    idempotencyKey: UUID().uuidString
                )
                await MainActor.run {
                    emailDelivery = result
                    message = result.failed == 0
                        ? "Invitations sent."
                        : "Some invitations could not be delivered. You can retry them or share the link another way."
                    isError = result.failed > 0
                }
            } catch let error as SharedReadingError {
                await MainActor.run { message = error.presentationMessage; isError = true }
            } catch {
#if DEBUG
                await MainActor.run { message = "Invitation delivery failed: \(String(describing: error))"; isError = true }
#else
                await MainActor.run { message = "Email delivery failed. You can still share the link."; isError = true }
#endif
            }
        }
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
}

#if canImport(UIKit)
private enum SharedReadingInvitationQRCode {
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
