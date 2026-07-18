import Foundation
import RishiCore
import RishiLogging

/// App DI sets this once at bootstrap so StoreKit singleton paths
/// (``CustomerEntitlements``, ``RestoreService``) can refresh
/// ``EntitlementService`` after a successful entitlement-sync POST.
/// Production wires it to ``EntitlementService/refreshSnapshot()``.
public enum EntitlementSyncHooks {
    nonisolated(unsafe) public static var onSynced: (@Sendable () async -> Void)?
}

/// Awaits entitlement sync for call sites that are bare singletons with no
/// dependency-injection surface today (``Store``, ``CustomerEntitlements``,
/// ``RestoreService``). Builds its own throwaway `WorkerClient` per call via
/// `EntitlementSyncEndpoint(...).send()` — the same pattern
/// `VerifyEndPont(...).send()` already uses in
/// `CustomerEntitlements.observeTransactionUpdates()`.
///
/// On success, invokes ``EntitlementSyncHooks/onSynced`` so Settings/gates
/// can refresh without waiting for paywall dismiss or the next foreground.
/// On failure, logs and rethrows so the caller can leave the StoreKit
/// transaction unfinished for `Transaction.unfinished` / `updates` replay.
///
/// ``PurchaseService`` does NOT use this helper — it already has a real DI
/// graph (``EntitlementSyncClient``) and keeps using that for testability.
func syncEntitlement(jws: String) async throws {
    do {
        let response = try await EntitlementSyncEndpoint(
            body: .init(transactionJWS: jws)
        ).send()
        Log.event("iap.entitlement_sync.done", level: .info,
                  data: ["verified": "\(response.verified)"])
        await EntitlementSyncHooks.onSynced?()
    } catch {
        Log.event("iap.entitlement_sync.failed", level: .warning,
                  data: ["error": String(describing: error)])
        throw error
    }
}
