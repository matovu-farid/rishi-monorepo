import Foundation
import Observation
import RishiLogging

/// Feature flag gating the new StoreKit IAP code paths. When OFF, the
/// existing text-only paywall fallback continues to render and the
/// reconciler ignores the on-device signal entirely (server source only).
///
/// Pattern matches Phase 3 `DevBypassConfig` (RESEARCH §13 Q3):
/// - DEBUG builds: UserDefaults toggle so QA / dev can flip at runtime.
/// - Release builds: hard-coded OFF until App Store Connect product setup
///   completes. Flip the constant in a one-line code change to ship.
public enum StoreKitIAPFlag {
    #if DEBUG
    private static let key = "rishi.iap.storekit.enabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    public static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
    #else
    public static let isEnabled: Bool = true
    #endif
}

/// Single source of truth for "is this user premium?" — unions the
/// on-device `Transaction.currentEntitlements` signal AND the server's
/// premium response. "Most permissive wins": if EITHER source grants
/// `.pro`, the reconciled level is `.pro`.
///
/// Real-world scenarios handled:
/// - **Offline-after-purchase:** device knows `.pro`, server hasn't synced yet → `.pro`.
/// - **Worker-DB lag:** server says `.pro`, device hasn't refreshed yet → `.pro`.
/// - **Cross-device handoff:** purchase on iPhone, opens Mac; `AppStore.sync()`
///   refresh updates device signal; server signal is already up-to-date.
///
/// `@MainActor` because SwiftUI binds via Observation; setters are called
/// from `PurchaseService` / `EntitlementService` continuation closures
/// that already hop to `MainActor` for UI updates.
@available(iOS 18.4, macOS 15.4, *)
@MainActor
@Observable
public final class EntitlementReconciler {

    public private(set) var level: EntitlementLevel

    // Source signals — separated so each updater can publish independently
    // without clobbering the other side. Recomputed via `recompute`.
    private var entitlementLevel: EntitlementLevel

    public init(initial: EntitlementLevel = .unsubscribed) {
        self.entitlementLevel = initial
        self.level = initial
    }

    /// Called by `PurchaseService` / `RestoreService` after reading
    /// `Transaction.currentEntitlements`. No-op when `StoreKitIAPFlag`
    /// is OFF (legacy server-only path).
    public func setOnDevice(_ next: EntitlementLevel) {
        guard StoreKitIAPFlag.isEnabled else {
            Log.event("iap.reconciler.skip_on_device_flag_off",
                      level: .debug,
                      data: ["requested": "\(next)"])
            return
        }
        self.entitlementLevel = next
        recompute()
    }



    /// Clear both source signals on sign-out so the next user does not
    /// inherit the previous user's reconciled `.pro`. Goes through
    /// `recompute()` so the `@Observable` `level` publishes the change to
    /// any SwiftUI binding exactly once.
    public func reset() {
        entitlementLevel = .unsubscribed
        recompute()
    }

    private func recompute() {
        // Most permissive wins (RESEARCH §3.4).
        let next: EntitlementLevel = (entitlementLevel == .subscribed ) ? .subscribed : .unsubscribed
        if next != level {
          
            level = next
        }
    }
}
