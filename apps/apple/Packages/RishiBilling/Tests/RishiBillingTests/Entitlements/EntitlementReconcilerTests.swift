import Foundation
import Observation
import Testing
@testable import RishiBilling

/// Truth-table coverage for EntitlementReconciler (IAP-04 / IAP-10).
///
/// The reconciler unions on-device (`Transaction.currentEntitlements`) AND
/// the server premium signal — "most permissive wins" per
/// 13-RESEARCH.md §3.4 and 13-CONTEXT.md "Entitlement reconciliation".
///
/// `StoreKitIAPFlag` gates the on-device signal: when OFF the reconciler
/// ignores on-device updates and stays whatever the server says (matches
/// legacy Phase-11 behaviour during the dark-launch window). The server
/// signal is always honoured.
///
/// `@Suite(.serialized)` because `StoreKitIAPFlag` reads/writes a single
/// process-wide UserDefaults key under `#if DEBUG`. Parallel suite
/// execution would race on the flag's storage.
@MainActor
@Suite("EntitlementReconciler union truth table", .serialized)
struct EntitlementReconcilerTests {

    // MARK: - Initial state

    @Test("Default initialiser → level == .free")
    func initialLevel_isFree() {
        let r = EntitlementReconciler()
        #expect(r.level == .free)
    }

    @Test("init(initial: .pro) → level == .pro")
    func initialLevel_canBePro() {
        let r = EntitlementReconciler(initial: .pro)
        #expect(r.level == .pro)
    }

    // MARK: - Union truth table

    @Test("server .pro + on-device .free → .pro (worker-DB-lag case)")
    func union_serverPro_onDeviceFree_yieldsPro() {
        let r = EntitlementReconciler()
        r.forceSet(onDevice: .free, server: .pro)
        #expect(r.level == .pro)
    }

    @Test("server .free + on-device .pro → .pro (offline-after-purchase case)")
    func union_serverFree_onDevicePro_yieldsPro() {
        let r = EntitlementReconciler()
        r.forceSet(onDevice: .pro, server: .free)
        #expect(r.level == .pro)
    }

    @Test("both .pro → .pro")
    func union_bothPro_yieldsPro() {
        let r = EntitlementReconciler()
        r.forceSet(onDevice: .pro, server: .pro)
        #expect(r.level == .pro)
    }

    @Test("both .free → .free")
    func union_bothFree_yieldsFree() {
        let r = EntitlementReconciler()
        r.forceSet(onDevice: .free, server: .free)
        #expect(r.level == .free)
    }

    @Test("refund cascade: pro,pro then free,free → drops to .free")
    func refund_dropsToFree() {
        let r = EntitlementReconciler()
        r.forceSet(onDevice: .pro, server: .pro)
        #expect(r.level == .pro)
        r.forceSet(onDevice: .free, server: .free)
        #expect(r.level == .free)
    }

    // MARK: - StoreKitIAPFlag gating

    @Test("flag OFF: setOnDevice(.pro) is a no-op (server signal independent)")
    func flagOff_setOnDevice_isNoOp() {
        let previous = StoreKitIAPFlag.isEnabled
        defer { StoreKitIAPFlag.setEnabled(previous) }
        StoreKitIAPFlag.setEnabled(false)

        let r = EntitlementReconciler()
        r.setOnDevice(.pro)
        // Server still default .free; on-device read suppressed → level stays .free.
        #expect(r.level == .free)
    }

    @Test("flag ON: setOnDevice(.pro) flips level to .pro")
    func flagOn_setOnDevice_updatesLevel() {
        let previous = StoreKitIAPFlag.isEnabled
        defer { StoreKitIAPFlag.setEnabled(previous) }
        StoreKitIAPFlag.setEnabled(true)

        let r = EntitlementReconciler()
        r.setOnDevice(.pro)
        #expect(r.level == .pro)
    }

    @Test("setServer(.pro) applies regardless of flag (server signal independent of StoreKit)")
    func setServer_alwaysApplies_regardlessOfFlag() {
        let previous = StoreKitIAPFlag.isEnabled
        defer { StoreKitIAPFlag.setEnabled(previous) }
        StoreKitIAPFlag.setEnabled(false)

        let r = EntitlementReconciler()
        r.setServer(.pro)
        #expect(r.level == .pro)
    }

    // MARK: - Observation propagation

    @Test("@Observable level change notifies tracker exactly once")
    func observation_levelChangeNotifies() async {
        let r = EntitlementReconciler()
        let counter = LockedCounter()

        withObservationTracking {
            _ = r.level
        } onChange: {
            counter.increment()
        }

        r.setServer(.pro)
        // Yield once so the onChange callback fires before we assert.
        await Task.yield()

        #expect(counter.value == 1)
    }
}

// MARK: - Helpers

/// Tiny lock-guarded counter for cross-isolation tracking from the
/// Observation `onChange` closure (which is `@Sendable () -> Void`).
final class LockedCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
