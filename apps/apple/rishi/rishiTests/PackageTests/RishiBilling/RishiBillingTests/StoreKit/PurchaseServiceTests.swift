@testable import rishi
import Foundation
import StoreKit
import StoreKitTest
import Testing


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

    private enum StoreKitTestSetupError: Error { case missingConfig, timedOut }

    /// Probe — true when StoreKit Test daemon is reachable.
    private func probeStoreKitTestDaemon() async -> Bool {
        let probe: [Product]? = await firstResult(timeout: 2) {
            try? await Product.products(for: [self.monthlyId])
        }
        return !(probe ?? []).isEmpty
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

    /// Build a fresh `.unsubscribed` reconciler on MainActor (mirrors
    /// RestoreServiceTests.makeReconciler).
    private func makeReconciler() async -> EntitlementReconciler {
        await MainActor.run { EntitlementReconciler(initial: .unsubscribed) }
    }

    private func makeService(
        verifier: any ReceiptVerifier,
        product: Product,
        reconciler: EntitlementReconciler,
        purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)? = nil,
        unfinishedTransactionStream:
            (@Sendable () -> AsyncStream<VerificationResult<Transaction>>)? = nil,
        transactionFinisher: (@Sendable (Transaction) async -> Void)? = nil
    ) -> PurchaseService {
        let fetcher = SingleProductFetcher(product: product)
        return PurchaseService(
            productFetcher: fetcher,
            verifier: verifier,
            reconciler: reconciler,
            // Stub sync so sync-before-finish does not leave txns unfinished
            // when the real WorkerClient is unreachable under `swift test`.
            entitlementSyncClient: StubEntitlementSyncClient(),
            // Production adds the authenticated app-account token here. The
            // StoreKit boundary tests intentionally inject the boundary call
            // so they do not depend on a persisted app session.
            purchaseClosure: purchaseClosure ?? { product in
                try await product.purchase()
            },
            unfinishedTransactionStream: unfinishedTransactionStream,
            transactionFinisher: transactionFinisher
        )
    }

    private func makeSuccessfulService(
        verifier: any ReceiptVerifier,
        product: Product,
        reconciler: EntitlementReconciler,
        transactionFinisher: (@Sendable (Transaction) async -> Void)? = nil
    ) async throws -> PurchaseService {
        guard let transaction: Transaction = await firstResult(timeout: 5, operation: {
            try? await self.session.buyProduct(identifier: self.monthlyId)
        }) else {
            throw StoreKitTestSetupError.timedOut
        }
        return makeService(
            verifier: verifier,
            product: product,
            reconciler: reconciler,
            purchaseClosure: { _ in .success(.verified(transaction)) },
            transactionFinisher: transactionFinisher
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
            let finishes = TransactionFinishRecorder()
            let service = try await self.makeSuccessfulService(
                verifier: verifier,
                product: product,
                reconciler: reconciler,
                transactionFinisher: { transaction in await finishes.record(transaction.id) }
            )

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .granted(let returnedUntil) = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            #expect(returnedUntil == until)
            #expect(verifier.calls.count == 1)
            #expect(verifier.calls.first?.productId == self.monthlyId)

            #expect(await finishes.ids.count == 1)
        }
    }

    // MARK: - Stuck-on-paywall fix: verified grant flips reconciler to .subscribed

    /// Same-session verified purchase flips the injected reconciler to
    /// `.subscribed` (with `StoreKitIAPFlag` ON), so `AppGate.resolve` routes the
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
            let service = try await self.makeSuccessfulService(verifier: verifier, product: product, reconciler: reconciler)

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .granted = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            let level = await MainActor.run { reconciler.level }
            #expect(level == .subscribed,
                    "verified purchase did not flip reconciler to .subscribed — user stays stuck on paywall")
        }
    }

    /// With `StoreKitIAPFlag` OFF, `setOnDevice` must no-op so the reconciler
    /// stays `.unsubscribed` even on a verified grant — mirrors
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
            let service = try await self.makeSuccessfulService(verifier: verifier, product: product, reconciler: reconciler)

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .granted = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            let level = await MainActor.run { reconciler.level }
            #expect(level == .unsubscribed,
                    "StoreKitIAPFlag OFF — setOnDevice must no-op")
        }
    }

    // MARK: - IAP-03 worker network failure → leave UNFINISHED

    @Test
    func testWorkerNetworkFailure_throwsAndDoesNotGrant() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier(result: .failure(
                VerifyReceiptError.network("offline")
            ))
            let reconciler = await self.makeReconciler()
            let service = try await self.makeSuccessfulService(verifier: verifier, product: product, reconciler: reconciler)

            await #expect(throws: PurchaseError.self) {
                _ = try await service.purchase(productId: self.monthlyId)
            }

            #expect(await MainActor.run { reconciler.level } == .unsubscribed,
                    "a worker network failure must not grant entitlement")
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
            let finishes = TransactionFinishRecorder()
            let service = try await self.makeSuccessfulService(
                verifier: verifier,
                product: product,
                reconciler: reconciler,
                transactionFinisher: { transaction in await finishes.record(transaction.id) }
            )

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .rejected(let reason) = outcome else {
                Issue.record("expected .rejected, got \(outcome)")
                return
            }
            #expect(reason == "replay_detected")
            #expect(await finishes.ids.count == 1)
        }
    }

    // MARK: - Entitlement sync verified:false → rejected, no grant / no sync hook

    @Test
    func testEntitlementSyncRejects_finishes_noReconcilerSubscribe_noOnSynced() async throws {
        try await withSKTestDaemon {
            let product = try await self.monthlyProduct()
            let verifier = StubReceiptVerifier(result: .success(
                .init(verified: true, premiumUntil: .distantFuture, reason: nil)
            ))
            let reconciler = await self.makeReconciler()
            let previousFlag = StoreKitIAPFlag.isEnabled
            StoreKitIAPFlag.setEnabled(true)
            defer { StoreKitIAPFlag.setEnabled(previousFlag) }

            guard let transaction: Transaction = await firstResult(timeout: 5, operation: {
                try? await self.session.buyProduct(identifier: self.monthlyId)
            }) else {
                throw StoreKitTestSetupError.timedOut
            }

            let syncedCounter = OnSyncedCallCounter()
            let finishes = TransactionFinishRecorder()
            let service = PurchaseService(
                productFetcher: SingleProductFetcher(product: product),
                verifier: verifier,
                reconciler: reconciler,
                entitlementSyncClient: StubEntitlementSyncClient(
                    result: .init(verified: false, reason: "app_account_token_mismatch")
                ),
                onEntitlementSynced: {
                    await syncedCounter.increment()
                },
                purchaseClosure: { _ in .success(.verified(transaction)) },
                transactionFinisher: { transaction in await finishes.record(transaction.id) }
            )

            let outcome = try await service.purchase(productId: self.monthlyId)
            guard case .rejected(let reason) = outcome else {
                Issue.record("expected .rejected, got \(outcome)")
                return
            }
            #expect(reason == "app_account_token_mismatch")
            let level = await MainActor.run { reconciler.level }
            #expect(level == .unsubscribed, "sync reject must not flip reconciler")
            #expect(await syncedCounter.count == 0, "onEntitlementSynced must not run on sync reject")

            #expect(await finishes.ids == [transaction.id])
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
            guard let transaction: Transaction = await firstResult(timeout: 5, operation: {
                try? await self.session.buyProduct(identifier: self.monthlyId)
            }) else {
                throw StoreKitTestSetupError.timedOut
            }
            let firstReconciler = await self.makeReconciler()
            let firstService = self.makeService(
                verifier: failVerifier,
                product: product,
                reconciler: firstReconciler,
                purchaseClosure: { _ in .success(.verified(transaction)) }
            )
            _ = try? await firstService.purchase(productId: self.monthlyId)
            #expect(failVerifier.calls.count == 1)

            let recoverVerifier = StubReceiptVerifier(result: .success(
                .init(verified: true, premiumUntil: .distantFuture, reason: nil)
            ))
            let secondReconciler = await self.makeReconciler()
            let secondService = self.makeService(
                verifier: recoverVerifier,
                product: product,
                reconciler: secondReconciler,
                unfinishedTransactionStream: {
                    AsyncStream { continuation in
                        continuation.yield(.verified(transaction))
                        continuation.finish()
                    }
                }
            )
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
            let service = try await self.makeSuccessfulService(verifier: blockingVerifier, product: product, reconciler: reconciler)

            let purchaseTask = Task { try await service.purchase(productId: self.monthlyId) }

            try await self.waitUntil(timeout: 2.0) {
                await blockingVerifier.callCount() >= 1
            }
            let preDispatchCount = await blockingVerifier.callCount()
            #expect(preDispatchCount == 1)

            if let unfinished = await self.unfinishedTransaction(for: self.monthlyId) {
                await service.processUpdate(.verified(unfinished), source: "test_listener")
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

    private func hasUnfinishedTransaction(for productID: String) async -> Bool {
        await unfinishedTransaction(for: productID) != nil
    }

    private func unfinishedTransaction(for productID: String) async -> Transaction? {
        await firstResult(timeout: 3) {
                for await result in Transaction.unfinished {
                    if case .verified(let transaction) = result,
                       transaction.productID == productID {
                        return transaction
                    }
                }
                return nil
            }
    }

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

private func firstResult<T: Sendable>(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withCheckedContinuation { continuation in
        let state = FirstResultState(continuation: continuation)
        let operationTask = Task {
            state.finish(await operation())
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            state.finish(nil)
        }
        state.install(operationTask: operationTask, timeoutTask: timeoutTask)
    }
}

private final class FirstResultState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func install(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func finish(_ result: T?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: result)
    }
}

// MARK: - Test-only fetchers

private struct StubEntitlementSyncClient: EntitlementSyncing {
    var result: EntitlementSyncResult = .init(verified: true, reason: nil)

    func sync(transactionJWS: String) async throws -> EntitlementSyncResult {
        result
    }
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

private actor TransactionFinishRecorder {
    private(set) var ids: [UInt64] = []

    func record(_ id: UInt64) {
        ids.append(id)
    }
}

private actor OnSyncedCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

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
