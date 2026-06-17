import Foundation
import Observation
import RishiLogging

/// SET-03 — drives the native "Delete Account" confirmation flow on
/// `SettingsScreen`. Replaces the former two-step `DeleteAccountFlow` sheet:
/// the native destructive `.alert` button is now the deliberate confirmation,
/// so there is no separate "arm" step.
///
/// `runDelete()` calls the injected `onDelete()` (the app layer wires this to
/// `AuthService.deleteAccount()`; the worker handles SIWA revoke per
/// WORKER-TICKETS Ticket 1). On success it logs `settings.account.deleted`
/// then calls `onDeleted()` so the parent can dismiss + transition to
/// signed-out. On failure it logs `settings.account.delete_failed` and exposes
/// a `deleteError` string for a second native alert — local state is NOT
/// cleared, since the worker hasn't deleted the row and the user can retry from
/// the same signed-in state.
@MainActor
@Observable
final class DeleteAccountModel {

    /// True while a delete is in flight; guards against re-entrant runs and
    /// backs the destructive button's progress/disabled state.
    private(set) var inFlight = false

    /// Non-nil after a failed delete; drives the failure alert. Set back to nil
    /// by the failure alert's binding when dismissed.
    var deleteError: String?

    private let onDelete: () async throws -> Void
    private let onDeleted: () -> Void

    init(
        onDelete: @escaping () async throws -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.onDelete = onDelete
        self.onDeleted = onDeleted
    }

    func runDelete() async {
        guard !inFlight else { return }
        inFlight = true
        deleteError = nil
        do {
            try await onDelete()
            Log.event("settings.account.deleted", level: .info, data: [:])
            inFlight = false
            onDeleted()
        } catch {
            Log.event(
                "settings.account.delete_failed",
                level: .error,
                data: ["error": String(describing: error)]
            )
            deleteError = "We couldn't delete your account. Check your connection and try again."
            inFlight = false
        }
    }
}
