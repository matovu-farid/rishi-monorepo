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
@Suite(.serialized)
struct PurchaseServiceTests {

    private let session: SKTestSession
    private let monthlyId = "org.fidexa.rishi.pro.monthly"

    init() throws {
        let s = try SKTestSession(configurationFileNamed: "Rishi")
        s.disableDialogs = true
        s.clearTransactions()
        s.resetToDefaultState()
        self.session = s
    }

    // MARK: - Helpers

    /// Load the monthly product from the active SKTestSession.
    private func monthlyProduct() async throws -> Product {
        let products = try await Product.products(for: [monthlyId])
        return try #require(products.first)
    }

    private func makeService(
        verifier: any ReceiptVerifier,
        product: Product,
        purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)? = nil
    ) -> PurchaseService {
        let fetcher = SingleProductFetcher(product: product)
        return PurchaseService(
            productFetcher: fetcher,
            verifier: verifier,
            purchaseClosure: purchaseClosure
        )
    }

    // MARK: - IAP-03 happy path

    @Test
    func testHappyPath_successfulPurchase_finishesAfterWorkerVerifies() async throws {
        let product = try await monthlyProduct()
        let until = Date(timeIntervalSince1970: 4_000_000_000)
        let verifier = StubReceiptVerifier(result: .success(
            .init(verified: true, premiumUntil: until, reason: nil)
        ))
        let service = makeService(verifier: verifier, product: product)

        let outcome = try await service.purchase(productId: monthlyId)
        guard case .granted(let returnedUntil) = outcome else {
            Issue.record("expected .granted, got \(outcome)")
            return
        }
        #expect(returnedUntil == until)
        #expect(verifier.calls.count == 1)
        #expect(verifier.calls.first?.productId == monthlyId)

        var unfinishedCount = 0
        for await result in Transaction.unfinished {
            if case .verified(let tx) = result, tx.productID == monthlyId {
                unfinishedCount += 1
            }
        }
        #expect(unfinishedCount == 0,
                "expected zero unfinished txns after verified purchase")
    }

    // MARK: - IAP-03 worker network failure → leave UNFINISHED

    @Test
    func testWorkerNetworkFailure_leavesTransactionUnfinished() async throws {
        let product = try await monthlyProduct()
        let verifier = StubReceiptVerifier(result: .failure(
            VerifyReceiptError.network("offline")
        ))
        let service = makeService(verifier: verifier, product: product)

        await #expect(throws: PurchaseError.self) {
            _ = try await service.purchase(productId: self.monthlyId)
        }

        var foundUnfinished = false
        for await result in Transaction.unfinished {
            if case .verified(let tx) = result, tx.productID == monthlyId {
                foundUnfinished = true
            }
        }
        #expect(foundUnfinished, "expected an unfinished txn after worker network failure")
    }

    // MARK: - IAP-03 worker rejects → finish, .rejected

    @Test
    func testWorkerRejects_finishesTransaction_outcomeRejected() async throws {
        let product = try await monthlyProduct()
        let verifier = StubReceiptVerifier(result: .success(
            .init(verified: false, premiumUntil: nil, reason: "replay_detected")
        ))
        let service = makeService(verifier: verifier, product: product)

        let outcome = try await service.purchase(productId: monthlyId)
        guard case .rejected(let reason) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(reason == "replay_detected")
        var unfinishedCount = 0
        for await result in Transaction.unfinished {
            if case .verified(let tx) = result, tx.productID == monthlyId {
                unfinishedCount += 1
            }
        }
        #expect(unfinishedCount == 0)
    }

    // MARK: - IAP-03 userCancelled via injected closure

    @Test
    func testUserCancelled_outcomeCancelled_noVerifierCall() async throws {
        let product = try await monthlyProduct()
        let verifier = StubReceiptVerifier()
        let service = makeService(
            verifier: verifier,
            product: product,
            purchaseClosure: { _ in .userCancelled }
        )

        let outcome = try await service.purchase(productId: monthlyId)
        #expect(outcome == .cancelled)
        #expect(verifier.calls.isEmpty)
    }

    // MARK: - IAP-03 pending → awaiting approval

    @Test
    func testPending_outcomeAwaitingApproval() async throws {
        let product = try await monthlyProduct()
        let verifier = StubReceiptVerifier()
        let service = makeService(
            verifier: verifier,
            product: product,
            purchaseClosure: { _ in .pending }
        )

        let outcome = try await service.purchase(productId: monthlyId)
        #expect(outcome == .awaitingApproval)
        #expect(verifier.calls.isEmpty)
    }

    // MARK: - IAP-03 product not loaded

    @Test
    func testProductNotLoaded_throwsProductNotLoaded() async throws {
        let product = try await monthlyProduct()
        let verifier = StubReceiptVerifier()
        let service = makeService(verifier: verifier, product: product)

        await #expect(throws: PurchaseError.self) {
            _ = try await service.purchase(productId: "org.fidexa.rishi.pro.does_not_exist")
        }
        #expect(verifier.calls.isEmpty)
    }

    // MARK: - IAP-03 replayUnfinished walks Transaction.unfinished

    @Test
    func testReplayUnfinished_processesUnfinishedTransactionsOnLaunch() async throws {
        let product = try await monthlyProduct()
        let failVerifier = StubReceiptVerifier(result: .failure(
            VerifyReceiptError.network("offline")
        ))
        let firstService = makeService(verifier: failVerifier, product: product)
        _ = try? await firstService.purchase(productId: monthlyId)
        #expect(failVerifier.calls.count == 1)

        let recoverVerifier = StubReceiptVerifier(result: .success(
            .init(verified: true, premiumUntil: .distantFuture, reason: nil)
        ))
        let secondService = makeService(verifier: recoverVerifier, product: product)
        await secondService.replayUnfinished()
        #expect(recoverVerifier.calls.count >= 1,
                "expected replayUnfinished to invoke the verifier at least once")
    }

    // MARK: - IAP-03 in-flight dedup: listener skips same-session purchase

    @Test
    func testInFlightDeduplication_listener_skips_same_session_purchase() async throws {
        let product = try await monthlyProduct()
        let blockingVerifier = BlockingStubReceiptVerifier()
        let service = makeService(verifier: blockingVerifier, product: product)

        let purchaseTask = Task { try await service.purchase(productId: self.monthlyId) }

        try await waitUntil(timeout: 2.0) {
            await blockingVerifier.callCount() >= 1
        }
        let preDispatchCount = await blockingVerifier.callCount()
        #expect(preDispatchCount == 1)

        var matched: VerificationResult<Transaction>?
        for await result in Transaction.unfinished {
            if case .verified(let tx) = result, tx.productID == monthlyId {
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

// MARK: - Test-only fetcher

private struct SingleProductFetcher: ProductFetching, @unchecked Sendable {
    let product: Product
    func rawProduct(for productId: String) async -> Product? {
        product.id == productId ? product : nil
    }
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
