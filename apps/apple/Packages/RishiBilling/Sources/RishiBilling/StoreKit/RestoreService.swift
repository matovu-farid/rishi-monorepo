import Foundation
import StoreKit
import RishiLogging

// MARK: - Public outcome / error types

/// User-facing outcome surfaced by ``RestoreService/restore()``.
///
/// Paywall (Wave 3 plan 13-05) reads this to decide whether to show a
/// "Welcome back, Pro" toast or a "Nothing to restore" notice.
public enum RestoreOutcome: Sendable, Equatable {
    /// One or more verified, non-revoked Rishi Pro entitlements found on
    /// the device. The reconciler has been flipped to `.pro` (subject to
    /// the StoreKitIAPFlag gate).
    case restored(productIds: [String])
    /// `Transaction.currentEntitlements` returned no verified, non-revoked
    /// entitlements matching the Rishi Pro tier. Reconciler is NOT touched
    /// so server-derived `.pro` (if any) is preserved.
    case nothingToRestore
}

/// Errors raised by ``RestoreService/restore()``.
public enum RestoreError: Error, Equatable, Sendable {
    /// `AppStore.sync()` threw. The reconciler is NOT touched.
    case syncFailed(String)
}

// MARK: - RestoreProtocol seam

/// Public protocol covering ``RestoreService/restore()``.
///
/// Extracted by plan 13-05 so the Wave-3 ``PaywallViewModel`` can depend
/// on the protocol (and tests can inject a `StubRestoreProvider`) without
/// requiring an SKTestSession-bound concrete actor. ``RestoreService``
/// itself conforms naturally; production callers continue to pass the
/// concrete actor.
public protocol RestoreProtocol: Sendable {
    func restore() async throws -> RestoreOutcome
}

// MARK: - Restore service actor

/// Drives the user-initiated Restore Purchases flow.
///
/// The Paywall (Wave 3 plan 13-05) and Settings (no entry yet) invoke this
/// service when the user explicitly taps "Restore Purchases".
///
/// **Why an actor.** Restore is composed of two awaited operations
/// (`AppStore.sync()` followed by a `for await` walk over
/// `Transaction.currentEntitlements`). Actor isolation keeps the
/// concurrent state model simple while letting MainActor UI call
/// `await restoreService.restore()` directly.
///
/// **NEVER call from app launch.** `AppStore.sync()` triggers an Apple ID
/// authentication prompt every time it runs (RESEARCH §10 Pitfall 6) —
/// calling it on every cold start would annoy users to no end. The
/// startup path reads `Transaction.currentEntitlements` directly (no
/// prompt); restore is a discrete user-initiated operation.
public actor RestoreService {

    private let reconciler: EntitlementReconciler

    /// Product ID prefix for the Rishi Pro tier — matches both
    /// `org.fidexa.rishi.pro.monthly` and `org.fidexa.rishi.pro.annual`.
    /// Centralized constant so future tiers cannot accidentally be missed
    /// by an out-of-band productID filter elsewhere.
    public static let productIdPrefix = "org.fidexa.rishi.pro."

    public init(reconciler: EntitlementReconciler) {
        self.reconciler = reconciler
    }

    /// User-initiated restore. NEVER call from app launch — triggers an
    /// Apple ID auth prompt (RESEARCH §10 Pitfall 6).
    ///
    /// Flow:
    /// 1. `AppStore.sync()` forces a refresh from Apple servers.
    /// 2. Walk `Transaction.currentEntitlements`, filtering on
    ///    `.verified` + `productID` prefix + `revocationDate == nil`
    ///    (RESEARCH §10 Pitfall 5 — refunded transactions can linger
    ///    in the sequence until they age out).
    /// 3. If any entitlements remain, hop to MainActor and call
    ///    `reconciler.setOnDevice(.pro)`. The reconciler's `setOnDevice`
    ///    no-ops when `StoreKitIAPFlag` is OFF, so this is safe behind
    ///    the dark-rollout feature flag.
    /// 4. If none, return `.nothingToRestore` without touching the
    ///    reconciler — preserves a server-derived `.pro` for users who
    ///    bought via another platform.
    @discardableResult
    public func restore() async throws -> RestoreOutcome {
        Log.event("iap.restore.start", level: .info)
        do {
            try await AppStore.sync()
        } catch {
            Log.event(
                "iap.restore.sync_failed",
                level: .warning,
                data: ["error": String(describing: error)]
            )
            throw RestoreError.syncFailed(String(describing: error))
        }

        let granted = await readActiveProductIds()
        if granted.isEmpty {
            Log.event("iap.restore.nothing", level: .info)
            return .nothingToRestore
        }

        await MainActor.run {
            self.reconciler.setOnDevice(.pro)
        }
        Log.event(
            "iap.restore.granted",
            level: .info,
            data: [
                "count": "\(granted.count)",
                "ids": granted.joined(separator: ","),
            ]
        )
        return .restored(productIds: granted)
    }

    /// Launch-time on-device entitlement reconciliation. Walks
    /// `Transaction.currentEntitlements` (NO `AppStore.sync()`, so no Apple ID
    /// prompt) and flips the reconciler to `.pro` if a verified, non-revoked
    /// Rishi Pro entitlement is present. This is the "startup path" referenced
    /// in this file's header: it restores Pro from the device on a cold launch
    /// independent of the server signal (which can be stale, or — for local
    /// StoreKit-test purchases — never aware of the purchase at all). Safe to
    /// call unconditionally at launch. No-op when `StoreKitIAPFlag` is OFF
    /// (the flip goes through `setOnDevice`, which is flag-gated).
    public func refreshOnDeviceEntitlementAtLaunch() async {
        let granted = await readActiveProductIds()
        guard !granted.isEmpty else {
            Log.event("iap.launch_reconcile.none", level: .info)
            return
        }
        await MainActor.run { self.reconciler.setOnDevice(.pro) }
        Log.event("iap.launch_reconcile.granted", level: .info,
                  data: ["count": "\(granted.count)",
                         "ids": granted.joined(separator: ",")])
    }

    /// Walks `Transaction.currentEntitlements`, filters to verified +
    /// non-revoked + Rishi Pro tier product IDs. Returns the matching ids.
    ///
    /// **Pitfall 5 — `revocationDate == nil`.** A refunded transaction
    /// can briefly remain in `currentEntitlements` until Apple ages it
    /// out. Without this filter, the user would keep Pro through the
    /// refund window — the load-bearing guard for this plan.
    private func readActiveProductIds() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            guard tx.productID.hasPrefix(Self.productIdPrefix) else { continue }
            guard tx.revocationDate == nil else { continue }
            ids.append(tx.productID)
        }
        return ids
    }
}

// MARK: - RestoreProtocol conformance (plan 13-05)
//
// Adopted via extension so the public protocol seam is wired without
// editing the actor declaration line. PaywallViewModel + tests can take
// `any RestoreProtocol`; production passes the concrete actor.
extension RestoreService: RestoreProtocol {}
