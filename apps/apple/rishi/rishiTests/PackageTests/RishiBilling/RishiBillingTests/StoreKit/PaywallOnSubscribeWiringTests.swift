@testable import rishi
import Foundation
import Testing


/// Quick-VPX Task 1 (GAP 1) — paywall onSubscribe wiring tests.
///
/// Verifies the `paywallSubscribeAction(...)` seam invoked by
/// `RootView.swift`'s paywall sheet onSubscribe closure. The seam is the
/// single point where the host app crosses from SwiftUI-land into the
/// RishiBilling purchase pipeline. Tests cover:
///
///  1. The seam forwards exactly the requested `productId` to the
///     injected `PurchaseProtocol` (no hardcoded SKU strings, no mutation).
///  2. `PurchaseOutcome.granted` → `onSuccess` exactly once.
///  3. `PurchaseOutcome.cancelled` → `onCancel` exactly once.
///  4. A thrown `PurchaseError` → `onError` exactly once with the thrown
///     error.
///
/// Pending (awaitingApproval) collapses to `onCancel` (silent dismiss) per
/// the Quick-VPX plan — the entitlement reconciler resolves the actual
/// outcome later via `Transaction.updates`.
///
/// Concurrency: tests are `@MainActor` (matches the action's MainActor
/// isolation). `SpyPurchaseService` is an `actor` so the recorded
/// `productIds` array crosses isolation boundaries safely under Swift 6
/// strict concurrency.
@MainActor
@Suite(.serialized)
struct PaywallOnSubscribeWiringTests {

    // MARK: - Test seam

    /// Spy conforming to `PurchaseProtocol`. Records every `productId`
    /// the action forwards, and replays one of:
    ///  - `granted` (success branch)
    ///  - `cancelled` (cancel branch)
    ///  - `awaitingApproval` (pending — collapses to cancel)
    ///  - `rejected(reason:)` (worker rejection — still success-branch-completes
    ///    per PurchaseOutcome semantics; tests do not cover this branch here)
    ///  - `throw_` (error branch)
    actor SpyPurchaseService: PurchaseProtocol {
        enum Mode: Sendable {
            case granted(Date?)
            case cancelled
            case awaitingApproval
            case rejected(String)
            case throw_(any Error & Sendable)
        }

        private(set) var productIds: [String] = []
        private let mode: Mode

        init(mode: Mode) { self.mode = mode }

        func purchase(productId: String) async throws -> PurchaseOutcome {
            productIds.append(productId)
            switch mode {
            case .granted(let until):    return .granted(premiumUntil: until)
            case .cancelled:             return .cancelled
            case .awaitingApproval:      return .awaitingApproval
            case .rejected(let reason):  return .rejected(reason: reason)
            case .throw_(let err):       throw err
            }
        }

        func recordedIds() -> [String] { productIds }
    }

    /// Synthetic error type for the error-branch test. Sendable + Equatable
    /// so the spy can `throw` it across the actor boundary cleanly.
    struct SpyError: Error, Equatable, Sendable {
        let tag: String
    }

    // MARK: - Helpers

    /// Drives `paywallSubscribeAction` and awaits the inner Task to
    /// completion via a fulfillment expectation built on Swift Testing
    /// `confirmation(...)`. Returns the spy so individual tests can read
    /// recorded product IDs.
    private func runAction(
        spy: SpyPurchaseService,
        productId: String,
        successCount: Int = 0,
        cancelCount: Int = 0,
        errorCount: Int = 0,
        errorAssertion: ((Error) -> Void)? = nil
    ) async {
        await confirmation("subscribe-action settled",
                           expectedCount: successCount + cancelCount + errorCount) { settled in
            paywallSubscribeAction(
                purchaseService: spy,
                productId: productId,
                onSuccess: {
                    #expect(successCount > 0, "unexpected onSuccess")
                    settled()
                },
                onCancel: {
                    #expect(cancelCount > 0, "unexpected onCancel")
                    settled()
                },
                onError: { err in
                    #expect(errorCount > 0, "unexpected onError")
                    errorAssertion?(err)
                    settled()
                }
            )
            // Yield to let the action's Task hop run.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Tests

    @Test("Forwards monthly product id to PurchaseService")
    func forwardsMonthlyProductId() async {
        let spy = SpyPurchaseService(mode: .granted(nil))
        await runAction(
            spy: spy,
            productId: StoreKitProductService.monthlyProductId,
            successCount: 1
        )
        let ids = await spy.recordedIds()
        #expect(ids == [StoreKitProductService.monthlyProductId])
        #expect(ids.first == "org.fidexa.rishi.pro.monthly")
    }

    @Test("Success outcome triggers onSuccess exactly once")
    func successBranch() async {
        let spy = SpyPurchaseService(mode: .granted(Date(timeIntervalSince1970: 1_780_000_000)))
        await runAction(
            spy: spy,
            productId: StoreKitProductService.monthlyProductId,
            successCount: 1
        )
        let ids = await spy.recordedIds()
        #expect(ids.count == 1)
    }

    @Test("User-cancelled outcome triggers onCancel exactly once")
    func cancelBranch() async {
        let spy = SpyPurchaseService(mode: .cancelled)
        await runAction(
            spy: spy,
            productId: StoreKitProductService.monthlyProductId,
            cancelCount: 1
        )
    }

    @Test("Pending (awaitingApproval) collapses to onCancel (silent dismiss)")
    func pendingCollapsesToCancel() async {
        let spy = SpyPurchaseService(mode: .awaitingApproval)
        await runAction(
            spy: spy,
            productId: StoreKitProductService.monthlyProductId,
            cancelCount: 1
        )
    }

    @Test("Thrown error triggers onError exactly once with the thrown error")
    func errorBranch() async {
        let thrown = SpyError(tag: "synthetic-store-kit-throw")
        let spy = SpyPurchaseService(mode: .throw_(thrown))
        await runAction(
            spy: spy,
            productId: StoreKitProductService.monthlyProductId,
            errorCount: 1,
            errorAssertion: { err in
                let casted = err as? SpyError
                #expect(casted == thrown)
            }
        )
    }
}
