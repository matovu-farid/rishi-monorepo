import Foundation
import RishiLogging

/// Quick-VPX Task 1 (GAP 1) — paywall onSubscribe seam.
///
/// `PaywallView(feature:onSubscribe:onDismiss:)` exposes a synchronous
/// `() -> Void` closure as its Subscribe affordance — but the underlying
/// `PurchaseProtocol.purchase(productId:)` is `async throws`. This helper
/// bridges the two by wrapping the awaiting call in a `Task` and
/// branching on `PurchaseOutcome` (plus the throwing path) into three
/// MainActor callbacks the host SwiftUI view can use to drive UI:
///
///   - `onSuccess` — `granted` AND `rejected(reason:)`. The user finished
///     a purchase round-trip; the host should dismiss the paywall. The
///     `EntitlementService` observation refreshes the actual entitlement
///     state on its own snapshot read (no manual mutation here).
///   - `onCancel` — `cancelled` AND `awaitingApproval`. Silent dismiss.
///     `awaitingApproval` (Ask-to-Buy / SCA) collapses to cancel because
///     the UI has no parental-approval surface today — the real outcome
///     arrives later via `Transaction.updates` and the entitlement
///     reconciler resolves it.
///   - `onError` — any thrown `PurchaseError` (or other error from a test
///     double). The host should dismiss the paywall AND emit a
///     `Log.event` breadcrumb. RishiLogging is the project's canonical
///     bridge — no direct Sentry call.
///
/// **Concurrency.** Declared `@MainActor` because every callback runs on
/// MainActor and the host SwiftUI closure is itself MainActor-isolated.
/// The inner `Task { @MainActor in ... }` inherits MainActor automatically
/// but the explicit annotation makes the contract self-documenting.
///
/// **Seam shape.** Pure free function (not a method on PurchaseService)
/// so the test double can be any `PurchaseProtocol` conformer — no need
/// to depend on a concrete actor in the test bundle.
@MainActor
public func paywallSubscribeAction(
    purchaseService: any PurchaseProtocol,
    productId: String,
    onSuccess: @escaping @MainActor () -> Void,
    onCancel:  @escaping @MainActor () -> Void,
    onError:   @escaping @MainActor (Error) -> Void
) {
    // KEEP: paywall seam. Outer Task is @MainActor because outcome callbacks
    // are @MainActor and the SwiftUI closure is MainActor-isolated. The
    // purchase() suspension itself is handled by the purchaseService actor.
    Task { @MainActor in
        do {
            let outcome = try await purchaseService.purchase(productId: productId)
            switch outcome {
            case .granted:
                onSuccess()
            case .cancelled:
                onCancel()
            case .awaitingApproval:
                // Pending / Ask-to-Buy / SCA — silent dismiss. The
                // entitlement reconciler will resolve the real outcome
                // when StoreKit posts to `Transaction.updates`.
                onCancel()
            case .rejected(let reason):
                // Worker rejected the receipt (replay / mismatch /
                // signature invalid). PurchaseService already finished
                // the transaction to break the loop. Treat as a silent
                // dismiss — emitting an error alert here would leak
                // worker-internal reasons to the user; the entitlement
                // reconciler is the source of truth for what the user
                // sees next. A breadcrumb is still emitted for triage.
                Log.event("paywall.purchase.rejected",
                          level: .warning,
                          data: ["productId": productId, "reason": reason])
                onCancel()
            }
        } catch {
            Log.event("paywall.purchase.failed",
                      level: .error,
                      data: ["productId": productId,
                             "error": String(describing: error)])
            onError(error)
        }
    }
}
