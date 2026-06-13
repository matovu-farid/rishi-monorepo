import SwiftUI
import RishiUIKit
import RishiLogging

/// SET-03 — two-step destructive flow. First tap arms the confirmation;
/// second tap calls `onDelete()` which the app layer wires to
/// `AuthService.deleteAccount()` (worker handles SIWA revoke per
/// WORKER-TICKETS Ticket 1).
///
/// Errors surface in an inline message WITHOUT clearing local state — the
/// worker hasn't deleted the row, so the user can retry from the same
/// signed-in state. Successful deletion calls `onDeleted()` so the parent
/// can dismiss + transition to signed-out.
struct DeleteAccountFlow: View {

    public let onDelete: () async throws -> Void
    public let onDeleted: () -> Void
    public let onCancel: () -> Void

    @State private var armed = false
    @State private var inFlight = false
    @State private var error: String?

    public init(
        onDelete: @escaping () async throws -> Void,
        onDeleted: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onDelete = onDelete
        self.onDeleted = onDeleted
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(RishiColor.danger)
                .accessibilityHidden(true)

            Text("Delete Account")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)

            Text("This will permanently delete your account, your library, your highlights, and your conversations. Your Rishi subscription will be cancelled on the next billing cycle from rishi.fidexa.org. This cannot be undone.")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)

            if let error {
                Text(error)
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.danger)
                    .padding(.horizontal, RishiSpacing.l)
                    .accessibilityIdentifier("settings-delete-error")
            }

            if armed {
                Button(role: .destructive) {
                    // KEEP: runDelete hops into RishiAuthService (actor) and
                    // updates local @State (inFlight, error). UI mutation.
                    Task { await runDelete() }
                } label: {
                    HStack {
                        if inFlight { ProgressView() }
                        Text("Permanently delete my account")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, RishiSpacing.m)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.danger)
                .disabled(inFlight)
                .padding(.horizontal, RishiSpacing.l)
                .accessibilityIdentifier("settings-delete-confirm")
            } else {
                Button(role: .destructive) {
                    armed = true
                } label: {
                    Text("Delete Account…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.danger)
                .padding(.horizontal, RishiSpacing.l)
                .accessibilityIdentifier("settings-delete-arm")
            }

            Button("Cancel", action: onCancel)
                .foregroundStyle(RishiColor.textSecondary)
                .accessibilityIdentifier("settings-delete-cancel")
        }
        .padding(RishiSpacing.l)
        .background(RishiColor.surfaceElevated.ignoresSafeArea())
    }

    private func runDelete() async {
        guard !inFlight else { return }
        inFlight = true
        error = nil
        do {
            try await onDelete()
            Log.event("settings.account.deleted", level: .info, data: [:])
            onDeleted()
        } catch {
            Log.event(
                "settings.account.delete_failed",
                level: .error,
                data: ["error": String(describing: error)]
            )
            self.error = "We couldn't delete your account. Check your connection and try again."
            inFlight = false
        }
    }
}

#Preview("Initial") {
    DeleteAccountFlow(onDelete: {}, onDeleted: {}, onCancel: {})
}
