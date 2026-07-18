import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import RishiBilling

/// PurchaseService — Plan 13-03 IAP-03.
///
/// Verifies the finish-after-verify ordering (RESEARCH §10 Pitfall 1) and
/// the same-session in-flight dedup against the Transaction.updates
/// listener (RESEARCH §10 Pitfall 3).
///
/// `.userCancelled` and `.pending` are driven via the injectable
/// `purchaseClosure` seam — SKTestSession cannot reliably synthesize those
/// outcomes at the StoreKit boundary, so PurchaseService exposes a closure
/// hook taking a Product and returning a Product.PurchaseResult.
///
/// **Host environment.** Same SKTestSession daemon caveat as
/// `StoreKitProductServiceTests` — `swift test` on a Mac host has no
/// daemon; products fail to load. Tests that require live products are
/// wrapped in `withSKTestDaemon` and report as `withKnownIssue` on hosts
/// without the daemon; tests that depend only on the injected closure or
/// the verifier stub run unconditionally.
@Suite(.serialized)
struct PurchaseServiceTests {

    private let session: SKTestSession
    private let monthlyId = "org.fidexa.rishi.pro.monthly"

    init() throws {
        // Bundle.module resolves the Rishi.storekit copied into the test
        // bundle by Package.swift's `resources:` block; the bundle-less
        // SKTestSession init only searches Bundle.main, which under
        // `swift test` is the xctest harness.
        guard let url = Bundle.module.url(forResource: "Rishi", withExtension: "storekit") else {
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

    /// Resolve the monthly product or fail the test (returns nil if the
    /// daemon dropped it).
    private func monthlyProduct() async throws -> Product {
        let products = try await Product.products(for: [monthlyId])
        return try #require(products.first)
    }

    /// Build a fresh `.free` reconciler on MainActor (mirrors
    /// RestoreServiceTests.makeReconciler).
    private func makeReconciler() async -> EntitlementReconciler {
        await MainActor.run { EntitlementReconciler(initial: .free) }
    }

    private func makeService(
        verifier: any ReceiptVerifier,
        product: Product,
        reconciler: EntitlementReconciler,
        purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)? = nil
    ) -> PurchaseService {
        let fetcher = SingleProductFetcher(product: product)
        return PurchaseService(
            productFetcher: fetcher,
            verifier: verifier,
            reconciler: reconciler,
            // Stub sync so sync-before-finish does not leave txns unfinished
            // when the real WorkerClient is unreachable under `swift test`.
            entitlementSyncClient: StubEntitlementSyncClient(),
            purchaseClosure: purchaseClosure
        )
    }

    // MARK: - IAP-03 happy path

    @Test
    func testHappyPath_successfulPurchase_finishesAfterWorkerVerifies() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let until = Date(timeIntervalSince1970: 4_000_000_000)
            let verifier = StubReceiptVerifier(result: .success(
                .init(verified: true, premiumUntil: until, reason: nil)
            ))
            let reconciler = await self.makeReconciler()
            let service = self.makeService(verifier: verifier, product: product, reconciler: reconciler)

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .granted(let returnedUntil) = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            #expect(returnedUntil == until)
            #expect(verifier.calls.count == 1)
            #expect(verifier.calls.first?.productId == self.monthlyId)

            var unfinishedCount = 0
            for await result in Transaction.unfinished {
                if case .verified(let tx) = result, tx.productID == self.monthlyId {
                    unfinishedCount += 1
                }
            }
            #expect(unfinishedCount == 0,
                    "expected zero unfinished txns after verified purchase")
        }
    }

    // MARK: - Stuck-on-paywall fix: verified grant flips reconciler to .pro

    /// Same-session verified purchase flips the injected reconciler to
    /// `.pro` (with `StoreKitIAPFlag` ON), so `AppGate.resolve` routes the
    /// user into the app instead of leaving them stuck on the paywall.
    /// Mirrors RestoreServiceTests' active-subscription assertion.
    @Test
    func testVerifiedPurchase_flagOn_flipsReconcilerToPro() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(true)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier(result: .success(
                .init(verified: true, premiumUntil: .distantFuture, reason: nil)
            ))
            let reconciler = await self.makeReconciler()
            let service = self.makeService(verifier: verifier, product: product, reconciler: reconciler)

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .granted = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            let level = await MainActor.run { reconciler.level }
            #expect(level == .pro,
                    "verified purchase did not flip reconciler to .pro — user stays stuck on paywall")
        }
    }

    /// With `StoreKitIAPFlag` OFF, `setOnDevice` must no-op so the reconciler
    /// stays `.free` even on a verified grant — mirrors
    /// RestoreServiceTests.testRestore_flagOff_setOnDeviceIsNoOp.
    @Test
    func testVerifiedPurchase_flagOff_reconcilerStaysFree() async throws {
        try await withSKTestDaemon {
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(false)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier(result: .success(
                .init(verified: true, premiumUntil: .distantFuture, reason: nil)
            ))
            let reconciler = await self.makeReconciler()
            let service = self.makeService(verifier: verifier, product: product, reconciler: reconciler)

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .granted = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            let level = await MainActor.run { reconciler.level }
            #expect(level == .free,
                    "StoreKitIAPFlag OFF — setOnDevice must no-op")
        }
    }

    // MARK: - IAP-03 worker network failure → leave UNFINISHED

    @Test
    func testWorkerNetworkFailure_leavesTransactionUnfinished() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier(result: .failure(
                VerifyReceiptError.network("offline")
            ))
            let reconciler = await self.makeReconciler()
            let service = self.makeService(verifier: verifier, product: product, reconciler: reconciler)

            await #expect(throws: PurchaseError.self) {
                _ = try await service.purchase(productId: self.monthlyId)
            }

            var foundUnfinished = false
            for await result in Transaction.unfinished {
                if case .verified(let tx) = result, tx.productID == self.monthlyId {
                    foundUnfinished = true
                }
            }
            #expect(foundUnfinished, "expected an unfinished txn after worker network failure")
        }
    }

    // MARK: - IAP-03 worker rejects → finish, .rejected

    @Test
    func testWorkerRejects_finishesTransaction_outcomeRejected() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier(result: .success(
                .init(verified: false, premiumUntil: nil, reason: "replay_detected")
            ))
            let reconciler = await self.makeReconciler()
            let service = self.makeService(verifier: verifier, product: product, reconciler: reconciler)

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .rejected(let reason) = outcome else {
                Issue.record("expected .rejected, got \(outcome)")
                return
            }
            #expect(reason == "replay_detected")
            var unfinishedCount = 0
            for await result in Transaction.unfinished {
                if case .verified(let tx) = result, tx.productID == self.monthlyId {
                    unfinishedCount += 1
                }
            }
            #expect(unfinishedCount == 0)
        }
    }

    // MARK: - IAP-03 userCancelled via injected closure (no daemon needed)

    @Test
    func testUserCancelled_outcomeCancelled_noVerifierCall() async throws {
        // Inject a Product via the closure path — we still need a Product
        // instance, which requires the daemon to construct. Guard.
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier()
            let reconciler = await self.makeReconciler()
            let service = self.makeService(
                verifier: verifier,
                product: product,
                reconciler: reconciler,
                purchaseClosure: { _ in .userCancelled }
            )

            let outcome = try await service.purchase(productId: self.monthlyId)
            #expect(outcome == .cancelled)
            #expect(verifier.calls.isEmpty)
        }
    }

    // MARK: - IAP-03 pending → awaiting approval

    @Test
    func testPending_outcomeAwaitingApproval() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier()
            let reconciler = await self.makeReconciler()
            let service = self.makeService(
                verifier: verifier,
                product: product,
                reconciler: reconciler,
                purchaseClosure: { _ in .pending }
            )

            let outcome = try await service.purchase(productId: self.monthlyId)
            #expect(outcome == .awaitingApproval)
            #expect(verifier.calls.isEmpty)
        }
    }

    // MARK: - IAP-03 product not loaded (daemon-independent)

    @Test
    func testProductNotLoaded_throwsProductNotLoaded() async throws {
        // No need for SKTestSession daemon — uses a fetcher that always
        // returns nil for the missing id. Runs unconditionally.
        let verifier = StubReceiptVerifier()
        let fetcher = AlwaysNilProductFetcher()
        let reconciler = await makeReconciler()
        let service = PurchaseService(
            productFetcher: fetcher,
            verifier: verifier,
            reconciler: reconciler,
            purchaseClosure: nil
        )

        await #expect(throws: PurchaseError.self) {
            _ = try await service.purchase(productId: "org.fidexa.rishi.pro.does_not_exist")
        }
        #expect(verifier.calls.isEmpty)
    }

    // MARK: - IAP-03 replayUnfinished walks Transaction.unfinished

    @Test
    func testReplayUnfinished_processesUnfinishedTransactionsOnLaunch() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let failVerifier = StubReceiptVerifier(result: .failure(
                VerifyReceiptError.network("offline")
            ))
            let firstReconciler = await self.makeReconciler()
            let firstService = self.makeService(verifier: failVerifier, product: product, reconciler: firstReconciler)
            _ = try? await firstService.purchase(productId: self.monthlyId)
            #expect(failVerifier.calls.count == 1)

            let recoverVerifier = StubReceiptVerifier(result: .success(
                .init(verified: true, premiumUntil: .distantFuture, reason: nil)
            ))
            let secondReconciler = await self.makeReconciler()
            let secondService = self.makeService(verifier: recoverVerifier, product: product, reconciler: secondReconciler)
            await secondService.replayUnfinished()
            #expect(recoverVerifier.calls.count >= 1,
                    "expected replayUnfinished to invoke the verifier at least once")
        }
    }

    // MARK: - IAP-03 in-flight dedup: listener skips same-session purchase

    @Test
    func testInFlightDeduplication_listener_skips_same_session_purchase() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let blockingVerifier = BlockingStubReceiptVerifier()
            let reconciler = await self.makeReconciler()
            let service = self.makeService(verifier: blockingVerifier, product: product, reconciler: reconciler)

            let purchaseTask = Task { try await service.purchase(productId: self.monthlyId) }

            try await self.waitUntil(timeout: 2.0) {
                await blockingVerifier.callCount() >= 1
            }
            let preDispatchCount = await blockingVerifier.callCount()
            #expect(preDispatchCount == 1)

            var matched: VerificationResult<Transaction>?
            for await result in Transaction.unfinished {
                if case .verified(let tx) = result, tx.productID == self.monthlyId {
                    matched = result
                    break
                }
            }
            if let synthetic = matched {
                await service.processUpdate(synthetic, source: "test_listener")
            }
            let midCount = await blockingVerifier.callCount()
            #expect(midCount == 1, "listener double-handled an in-flight txn")

            await blockingVerifier.release(
                with: .init(verified: true, premiumUntil: .distantFuture, reason: nil)
            )
            _ = try? await purchaseTask.value
        }
    }

    // MARK: - Test utilities

    private func waitUntil(
        timeout: TimeInterval,
        _ predicate: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        Issue.record("waitUntil timed out after \(timeout)s")
    }
}

// MARK: - Test-only fetchers

private struct StubEntitlementSyncClient: EntitlementSyncing {
    func sync(transactionJWS: String) async throws {}
}

private struct SingleProductFetcher: ProductFetching, @unchecked Sendable {
    let product: Product
    func rawProduct(for productId: String) async -> Product? {
        product.id == productId ? product : nil
    }
}

private struct AlwaysNilProductFetcher: ProductFetching {
    func rawProduct(for productId: String) async -> Product? { nil }
}

// MARK: - Blocking stub for in-flight dedup test

private actor BlockingStubReceiptVerifier: ReceiptVerifier {

    private var callsCount: Int = 0
    private var continuation: CheckedContinuation<VerifyReceiptResponse, Error>?
    private var releaseValue: VerifyReceiptResponse?

    func callCount() -> Int { callsCount }

    func release(with response: VerifyReceiptResponse) {
        releaseValue = response
        continuation?.resume(returning: response)
        continuation = nil
    }

    nonisolated func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse {
        try await bumpAndWait()
    }

    private func bumpAndWait() async throws -> VerifyReceiptResponse {
        callsCount += 1
        if let releaseValue { return releaseValue }
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }
}
