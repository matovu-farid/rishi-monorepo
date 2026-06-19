import Foundation
import StoreKit
import Testing
@testable import RishiBilling

/// TransactionListener — Plan 13-03 IAP-04.
///
/// Verifies the start()/stop() lifecycle and idempotency. Listener uses
/// Task.detached(priority: .background) (RESEARCH §10 Pitfall 12) so the
/// for-await loop never inherits MainActor isolation.
///
/// End-to-end Transaction.updates forwarding is covered by the integration
/// happy-path test in PurchaseServiceTests; here we exercise the wiring via
/// an injected MockPurchaseUpdateForwarder so we don't require an active
/// SKTestSession in every test method.
@Suite("TransactionListener")
struct TransactionListenerTests {

    @Test
    func testStart_installsTask() async {
        let mock = MockPurchaseUpdateForwarder()
        let listener = TransactionListener(forwarder: mock)
        let runningBefore = await listener.isRunning
        #expect(runningBefore == false)
        await listener.start()
        let runningAfter = await listener.isRunning
        #expect(runningAfter == true)
        await listener.stop()
    }

    @Test
    func testStart_isIdempotent_singleTask() async {
        let mock = MockPurchaseUpdateForwarder()
        let listener = TransactionListener(forwarder: mock)
        await listener.start()
        await listener.start()
        await listener.start()
        let running = await listener.isRunning
        #expect(running == true)
        await listener.stop()
    }

    @Test
    func testStop_cancelsTask() async {
        let mock = MockPurchaseUpdateForwarder()
        let listener = TransactionListener(forwarder: mock)
        await listener.start()
        await listener.stop()
        let running = await listener.isRunning
        #expect(running == false)
    }

    @Test
    func testStop_isIdempotent() async {
        let mock = MockPurchaseUpdateForwarder()
        let listener = TransactionListener(forwarder: mock)
        await listener.stop()
        await listener.start()
        await listener.stop()
        await listener.stop()
        let running = await listener.isRunning
        #expect(running == false)
    }

    @Test
    func testForwarderProtocol_PurchaseServiceConforms() async {
        func accepts(_ forwarder: any PurchaseUpdateForwarder) {}
        let fetcher = NoopProductFetcher()
        let verifier = StubReceiptVerifier()
        let reconciler = await MainActor.run { EntitlementReconciler(initial: .free) }
        let service = PurchaseService(productFetcher: fetcher, verifier: verifier, reconciler: reconciler)
        accepts(service)
    }

    @Test
    func testMockForwarder_recordsProcessUpdateCalls() async {
        let mock = MockPurchaseUpdateForwarder()
        let beforeCount = await mock.callCount()
        #expect(beforeCount == 0)
        await mock.bump()
        let afterCount = await mock.callCount()
        #expect(afterCount == 1)
    }
}

actor MockPurchaseUpdateForwarder: PurchaseUpdateForwarder {
    private var processCalls: Int = 0
    func callCount() -> Int { processCalls }
    func bump() { processCalls += 1 }

    nonisolated func processUpdate(
        _ result: VerificationResult<Transaction>,
        source: String
    ) async {
        await bump()
    }
}

private struct NoopProductFetcher: ProductFetching {
    func rawProduct(for productId: String) async -> Product? { nil }
}
