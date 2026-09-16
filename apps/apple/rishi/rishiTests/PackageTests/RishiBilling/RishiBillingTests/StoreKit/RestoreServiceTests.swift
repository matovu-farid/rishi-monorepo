@testable import rishi
import Foundation
import StoreKit
import StoreKitTest
import Testing


/// RestoreService — Plan 13-06 IAP-06.
///
/// Verifies the user-initiated Restore Purchases path:
///   1. AppStore.sync() forces a refresh from Apple servers.
///   2. Transaction.currentEntitlements is re-walked.
///   3. Verified + non-revoked transactions whose productID belongs to the
///      active Reader/Voice catalog flip `EntitlementReconciler.setOnDevice(.pro)`.
///
/// The `revocationDate == nil` filter is load-bearing — refunded transactions
/// can linger in `currentEntitlements` briefly (RESEARCH §10 Pitfall 5). Tests
/// drive a refund via SKTestSession and assert the refunded transaction does
/// NOT grant Pro.
///
/// **Host environment.** Same SKTestSession daemon caveat as
/// `PurchaseServiceTests` / `StoreKitProductServiceTests` — `swift test` on a
/// Mac host has no daemon. Tests that drive a buy are wrapped in
/// `withSKTestDaemon` and report as `withKnownIssue` on hosts without the
/// daemon. Tests that only exercise the no-purchases / sync-failure paths
/// run unconditionally where possible.
@MainActor
@Suite(.serialized)
struct RestoreServiceTests {

    private let session: SKTestSession
    private let monthlyId = RishiProductID.readerMonthly

    init() throws {
        // PackageTestResourceBundle.bundle resolves the Rishi.storekit copied into the test
        // bundle by Package.swift's `resources:` block; the bundle-less
        // SKTestSession init only searches Bundle.main, which under
        // `swift test` is the xctest harness.
        guard let url = PackageTestResourceBundle.bundle.url(forResource: "Rishi", withExtension: "storekit") else {
            Issue.record("Rishi.storekit missing from test bundle")
            throw StoreKitTestSetupError.missingConfig
        }
        let s = try SKTestSession(contentsOf: url)
        s.disableDialogs = true
        s.clearTransactions()
        s.resetToDefaultState()
        self.session = s
    }

    private enum StoreKitTestSetupError: Error { case missingConfig }

    /// Probe — true when StoreKit Test daemon is reachable.
    private func probeStoreKitTestDaemon() async -> Bool {
        let probe = (try? await Product.products(for: [monthlyId])) ?? []
        return !probe.isEmpty
    }

    /// Run `body` only when the StoreKit Test daemon is up; otherwise
    /// record a `withKnownIssue` so the test reports as soft-skip.
    private func withSKTestDaemon(_ body: () async throws -> Void) async throws {
        if await probeStoreKitTestDaemon() {
            try await body()
        } else {
            withKnownIssue("SKTestSession daemon unavailable on this host — run via xcodebuild on an iOS simulator destination.") {
                Issue.record("skipped — no StoreKit Test daemon")
            }
        }
    }

    /// Helper: build a fresh `.free` reconciler on MainActor.
    private func makeReconciler() -> EntitlementReconciler {
        EntitlementReconciler(initial: .free)
    }

    @Test
    func restore_successSyncsOnlyCurrentPlatformProducts() async throws {
        let reconciler = makeReconciler()
        let lock = CallRecorder()
        let service = RestoreService(
            reconciler: reconciler,
            appStoreSync: {},
            activeEntitlements: {
                [
                    RestoreEntitlement(productID: RishiProductID.proMonthly, jws: "legacy"),
                    RestoreEntitlement(productID: RishiProductID.readerMonthly, jws: "reader"),
                ]
            },
            entitlementSync: { jws in
                await lock.append(jws)
                return EntitlementSyncResult(verified: true, reason: nil)
            }
        )

        let outcome = try await service.restore()

        #expect(outcome == .restored(productIds: [RishiProductID.readerMonthly]))
        #expect(await lock.values() == ["reader"])
    }

    @Test
    func restore_withNoEntitlements_returnsNothingToRestoreWithoutSync() async throws {
        let lock = CallRecorder()
        let service = RestoreService(
            reconciler: makeReconciler(),
            appStoreSync: {},
            activeEntitlements: { [] },
            entitlementSync: { _ in
                await lock.append("unexpected")
                return EntitlementSyncResult(verified: true, reason: nil)
            }
        )

        #expect(try await service.restore() == .nothingToRestore)
        #expect(await lock.values().isEmpty)
    }

    @Test
    func restore_whenEntitlementSyncFails_doesNotReportRestored() async throws {
        let reconciler = makeReconciler()
        let service = RestoreService(
            reconciler: reconciler,
            appStoreSync: {},
            activeEntitlements: {
                [RestoreEntitlement(productID: RishiProductID.readerMonthly, jws: "reader")]
            },
            entitlementSync: { _ in throw RestoreTestError.syncFailed }
        )

        await #expect(throws: RestoreError.self) {
            _ = try await service.restore()
        }
        #expect(reconciler.level == .free)
    }

    private actor CallRecorder {
        private var recorded: [String] = []
        func append(_ value: String) { recorded.append(value) }
        func values() -> [String] { recorded }
    }

    private enum RestoreTestError: Error { case syncFailed }

    // MARK: - No purchases path (daemon-independent)

    @Test
    func testRestore_userWithNoEntitlements_returnsNothingToRestore() async throws {
        // Even without the daemon, AppStore.sync() resolves locally against
        // the SKTestSession; an empty `currentEntitlements` walk returns
        // .nothingToRestore. If sync itself throws on hosts without the
        // daemon, we accept that as a known-issue soft-skip.
        let reconciler = makeReconciler()
        let service = RestoreService(reconciler: reconciler)
        do {
            let outcome = try await service.restore()
            #expect(outcome == .nothingToRestore)
            #expect(reconciler.level == .free)
        } catch RestoreError.syncFailed {
            // Host without daemon — sync threw. Soft-skip via known-issue.
            withKnownIssue("AppStore.sync() failed on this host (no SKTestSession daemon).") {
                Issue.record("skipped — sync threw")
            }
        }
    }

    // MARK: - Active subscription path (SKTestSession-driven)

    @Test
    func testRestore_userWithActiveSubscription_returnsRestoredAndFlipsReconciler() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(true)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            // Drive a sandbox buy via SKTestSession so currentEntitlements
            // surfaces the monthly tier as active. The Swift API returns
            // a StoreKit.Transaction.
            _ = try await self.session.buyProduct(identifier: self.monthlyId)

            let reconciler = self.makeReconciler()
            let service = RestoreService(reconciler: reconciler)
            let outcome = try await service.restore()

            guard case let .restored(ids) = outcome else {
                Issue.record("expected .restored, got \(outcome)")
                return
            }
            #expect(ids.contains(self.monthlyId))
            #expect(reconciler.level == .pro)
        }
    }

    // MARK: - Revoked / refunded transaction is FILTERED OUT (Pitfall 5)

    @Test
    func testRestore_filtersRevokedTransactions() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(true)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            // Buy → refund: SKTestSession surfaces the transaction with a
            // non-nil revocationDate. The restore filter MUST drop it.
            let tx = try await self.session.buyProduct(identifier: self.monthlyId)
            try self.session.refundTransaction(identifier: UInt(tx.id))

            let reconciler = self.makeReconciler()
            let service = RestoreService(reconciler: reconciler)
            let outcome = try await service.restore()

            // The refunded transaction may either be absent from
            // currentEntitlements entirely OR present with a non-nil
            // revocationDate. Either way the restore path treats the user
            // as having nothing to restore.
            if case .restored(let ids) = outcome {
                #expect(!ids.contains(self.monthlyId),
                        "refunded transaction leaked into restored ids")
            } else {
                #expect(outcome == .nothingToRestore)
            }
            #expect(reconciler.level == .free,
                    "reconciler granted .pro from a refunded transaction (Pitfall 5)")
        }
    }

    // MARK: - StoreKitIAPFlag OFF → setOnDevice no-ops

    @Test
    func testRestore_flagOff_setOnDeviceIsNoOp() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(false)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            _ = try await self.session.buyProduct(identifier: self.monthlyId)

            let reconciler = self.makeReconciler()
            let service = RestoreService(reconciler: reconciler)
            let outcome = try await service.restore()

            // The restore CALL still returns the granted ids because the
            // entitlement read is independent of the flag; the flag only
            // gates whether the reconciler accepts the on-device signal.
            if case .restored = outcome {
                // expected — but reconciler level stays .free
            }
            #expect(reconciler.level == .free,
                    "StoreKitIAPFlag OFF — setOnDevice must no-op")
        }
    }

    // MARK: - Launch-time on-device reconciliation (no AppStore.sync prompt)

    @Test
    func testRefreshOnDeviceEntitlementAtLaunch_activeSubscription_flipsToPro() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(true)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            // Drive a sandbox buy so currentEntitlements surfaces the monthly
            // tier as active. The launch reconciler must detect it WITHOUT
            // AppStore.sync() (which is never called in this path).
            _ = try await self.session.buyProduct(identifier: self.monthlyId)

            let reconciler = self.makeReconciler()
            let service = RestoreService(reconciler: reconciler)
            await service.refreshOnDeviceEntitlementAtLaunch()

            #expect(reconciler.level == .pro)
        }
    }

    @Test
    func testRefreshOnDeviceEntitlementAtLaunch_flagOff_doesNotFlip() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(false)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            _ = try await self.session.buyProduct(identifier: self.monthlyId)

            let reconciler = self.makeReconciler()
            let service = RestoreService(reconciler: reconciler)
            await service.refreshOnDeviceEntitlementAtLaunch()

            #expect(reconciler.level == .free,
                    "StoreKitIAPFlag OFF — setOnDevice must no-op")
        }
    }

    @Test
    func testRefreshOnDeviceEntitlementAtLaunch_noEntitlements_doesNotFlip() async throws {
        // Daemon-independent: a fresh SKTestSession with cleared transactions
        // has no entitlements, so the launch reconciler must leave .free intact.
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = makeReconciler()
        let service = RestoreService(reconciler: reconciler)
        await service.refreshOnDeviceEntitlementAtLaunch()

        #expect(reconciler.level == .free)
    }

}
