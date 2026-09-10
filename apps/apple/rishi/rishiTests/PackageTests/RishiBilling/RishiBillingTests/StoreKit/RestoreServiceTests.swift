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
///      active Reader/Voice catalog flip `EntitlementReconciler.setOnDevice(.subscribed)`.
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

    /// Helper: build a fresh `.unsubscribed` reconciler on MainActor.
    private func makeReconciler() -> EntitlementReconciler {
        EntitlementReconciler(initial: .unsubscribed)
    }

    @Test
    func restore_successSyncsRecognizedProducts() async throws {
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

        #expect(outcome == .restored(productIds: [
            RishiProductID.proMonthly,
            RishiProductID.readerMonthly,
        ]))
        #expect(await lock.values() == ["legacy", "reader"])
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
        #expect(reconciler.level == .unsubscribed)
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
        // This test covers the empty-entitlement decision independently of
        // Apple's restore prompt. The injected sync closure leaves the
        // prompt-dependent behavior to the dedicated sync-failure test.
        let reconciler = makeReconciler()
        let service = RestoreService(
            reconciler: reconciler,
            appStoreSync: {},
            activeEntitlements: { [] }
        )
        #expect(try await service.restore() == .nothingToRestore)
        #expect(reconciler.level == .unsubscribed)
    }

    // MARK: - Active subscription path (SKTestSession-driven)

    @Test
    func testRestore_activeEntitlement_returnsRestoredAndFlipsReconciler() async throws {
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = makeReconciler()
        let service = RestoreService(
            reconciler: reconciler,
            appStoreSync: {},
            activeEntitlements: {
                [RestoreEntitlement(productID: self.monthlyId, jws: "test")]
            },
            entitlementSync: { _ in .init(verified: true, reason: nil) }
        )
        let outcome = try await service.restore()

        #expect(outcome == .restored(productIds: [monthlyId]))
        #expect(reconciler.level == .subscribed)
    }

    // MARK: - Revoked / refunded transaction is FILTERED OUT (Pitfall 5)

    @Test
    func testRestore_filtersRevokedEntitlements() async throws {
        let reconciler = makeReconciler()
        let syncCalls = CallRecorder()
        let service = RestoreService(
            reconciler: reconciler,
            appStoreSync: {},
            activeEntitlements: {
                [RestoreEntitlement(
                    productID: self.monthlyId,
                    jws: "revoked",
                    revocationDate: Date()
                )]
            },
            entitlementSync: { jws in
                await syncCalls.append(jws)
                return .init(verified: true, reason: nil)
            }
        )

        #expect(try await service.restore() == .nothingToRestore)
        #expect(await syncCalls.values().isEmpty)
        #expect(reconciler.level == .unsubscribed)
    }

    // MARK: - StoreKitIAPFlag OFF → setOnDevice no-ops

    @Test
    func testRestore_flagOff_setOnDeviceIsNoOp() async throws {
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(false)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = makeReconciler()
        let service = RestoreService(
            reconciler: reconciler,
            appStoreSync: {},
            activeEntitlements: {
                [RestoreEntitlement(productID: self.monthlyId, jws: "test")]
            },
            entitlementSync: { _ in .init(verified: true, reason: nil) }
        )
        let outcome = try await service.restore()

        #expect(outcome == .restored(productIds: [monthlyId]))
        #expect(reconciler.level == .unsubscribed,
                "StoreKitIAPFlag OFF — setOnDevice must no-op")
    }

    // MARK: - Launch-time on-device reconciliation (no AppStore.sync prompt)

    @Test
    func testRefreshOnDeviceEntitlementAtLaunch_activeEntitlement_flipsToPro() async throws {
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = makeReconciler()
        let service = RestoreService(
            reconciler: reconciler,
            activeEntitlements: {
                [RestoreEntitlement(productID: self.monthlyId, jws: "test")]
            }
        )
        await service.refreshOnDeviceEntitlementAtLaunch()

        #expect(reconciler.level == .subscribed)
    }

    @Test
    func testRefreshOnDeviceEntitlementAtLaunch_flagOff_doesNotFlip() async throws {
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(false)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = makeReconciler()
        let service = RestoreService(
            reconciler: reconciler,
            activeEntitlements: {
                [RestoreEntitlement(productID: self.monthlyId, jws: "test")]
            }
        )
        await service.refreshOnDeviceEntitlementAtLaunch()

        #expect(reconciler.level == .unsubscribed,
                "StoreKitIAPFlag OFF — setOnDevice must no-op")
    }

    @Test
    func testRefreshOnDeviceEntitlementAtLaunch_noEntitlements_doesNotFlip() async throws {
        // Daemon-independent: a fresh SKTestSession with cleared transactions
        // has no entitlements, so the launch reconciler must leave .unsubscribed intact.
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = makeReconciler()
        let service = RestoreService(reconciler: reconciler)
        await service.refreshOnDeviceEntitlementAtLaunch()

        #expect(reconciler.level == .unsubscribed)
    }

}
