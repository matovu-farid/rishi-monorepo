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
    public static let isEnabled: Bool = false
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
@MainActor
@Observable
public final class EntitlementReconciler {

    /// Reconciled level — most permissive wins. SwiftUI views reading
    /// this register with the Observation framework and update on change.
    public private(set) var level: EntitlementLevel

    // Source signals — separated so each updater can publish independently
    // without clobbering the other side. Recomputed via `recompute`.
    private var onDevice: EntitlementLevel
    private var server: EntitlementLevel

    public init(initial: EntitlementLevel = .free) {
        self.onDevice = initial
        self.server = initial
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
        self.onDevice = next
        recompute()
    }

    /// Called by `EntitlementService` after the worker premium response.
    /// Server signal is independent of `StoreKitIAPFlag` — the worker
    /// remains authoritative regardless of StoreKit rollout.
    public func setServer(_ next: EntitlementLevel) {
        self.server = next
        recompute()
    }

    /// Test-only seam: force-set both signals at once so the union
    /// truth-table tests can exercise every quadrant without going
    /// through StoreKit or the worker. Intentionally `internal` —
    /// production code MUST go through `setOnDevice` / `setServer`.
    func forceSet(onDevice: EntitlementLevel, server: EntitlementLevel) {
        self.onDevice = onDevice
        self.server = server
        recompute()
    }

    private func recompute() {
        // Most permissive wins (RESEARCH §3.4).
        let next: EntitlementLevel = (onDevice == .pro || server == .pro) ? .pro : .free
        if next != level {
            Log.event("iap.reconciler.level_changed",
                      level: .info,
                      data: ["from": "\(level)",
                             "to": "\(next)",
                             "onDevice": "\(onDevice)",
                             "server": "\(server)"])
            level = next
        }
    }
}
