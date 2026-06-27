import Foundation
import StoreKit
import RishiLogging

// MARK: - Public outcome / error types

/// User-facing outcome surfaced by ``PurchaseService/purchase(productId:)``.
public enum PurchaseOutcome: Sendable, Equatable {
    /// Worker confirmed the receipt; entitlement is granted. `premiumUntil`
    /// is the canonical expiry the worker persisted in `users.premium_until`.
    case granted(premiumUntil: Date?)
    /// User cancelled the StoreKit purchase sheet. No state change.
    case cancelled
    /// `.pending` — parental approval / SCA / Ask-to-Buy. UI should show a
    /// "Waiting for approval" state; the real outcome arrives later via
    /// `Transaction.updates`.
    case awaitingApproval
    /// Worker actively rejected (replay / mismatch / signature invalid).
    /// Transaction was finished to break the loop; reconciler NOT granted.
    case rejected(reason: String)
}

/// Errors raised by ``PurchaseService/purchase(productId:)``. Surfaces to the
/// paywall UI which renders an alert.
public enum PurchaseError: Error, Equatable, Sendable {
    /// `productService.rawProduct(for:)` returned nil; usually means
    /// `StoreKitProductService.load()` has not run yet.
    case productNotLoaded(productId: String)
    /// `VerificationResult.payloadValue` threw — JWS tamper detected.
    /// Transaction is NOT finished; Apple replays it through `Transaction.updates`.
    case unverifiedReceipt
    /// Worker network failure. Transaction is left UNFINISHED for
    /// `Transaction.unfinished` to replay on next launch.
    case workerUnreachable(String)
    /// `Product.purchase()` threw before yielding any result.
    case storeKit(String)
}

// MARK: - PurchaseProtocol seam

/// Public protocol covering ``PurchaseService/purchase(productId:)``.
///
/// Extracted by plan 13-05 so the Wave-3 ``PaywallViewModel`` can depend
/// on the protocol (and tests can inject a `StubPurchaseProvider`) without
/// dragging in an SKTestSession-bound concrete actor. ``PurchaseService``
/// itself conforms naturally; production callers continue to pass the
/// concrete actor.
public protocol PurchaseProtocol: Sendable {
    func purchase(productId: String) async throws -> PurchaseOutcome
}

// MARK: - Purchase service actor

/// Drives the StoreKit purchase flow, enforces the load-bearing
/// "worker-verify-then-finish" ordering (RESEARCH §10 Pitfall 1), and
/// tracks in-flight transaction IDs so the `Transaction.updates` listener
/// does not double-handle a same-session purchase (Pitfall 3).
///
/// Conforms to ``PurchaseUpdateForwarder`` so a ``TransactionListener`` can
/// forward `Transaction.updates` events straight to ``processUpdate(_:source:)``
/// without a separate adapter layer.
///
/// Adopts ``PurchaseProtocol`` (plan 13-05) via the extension at the
/// bottom of this file so the Wave-3 paywall view-model can depend on
/// the protocol seam instead of the concrete actor.
@available(iOS 18.4, *)
public actor PurchaseService: PurchaseUpdateForwarder {

    // MARK: Dependencies

    private let productFetcher: any ProductFetching
    private let verifier: any ReceiptVerifier
    private let reconciler: EntitlementReconciler
    private let purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)

    // MARK: State

    /// Transaction IDs we are currently verifying with the worker. The
    /// `Transaction.updates` listener consults this set in
    /// ``processUpdate(_:source:)`` and skips any txn whose ID is in
    /// flight — prevents double-verification when both the same-session
    /// purchase path AND the listener see the same event (RESEARCH §10
    /// Pitfall 3).
    private var inFlightTransactionIds: Set<UInt64> = []

    // MARK: Init

    /// Designated initializer.
    ///
    /// - Parameter reconciler: Flipped to `.pro` after a verified grant so
    ///   the app gate routes into the app instead of leaving the user
    ///   stuck on the paywall. Mirrors ``RestoreService``. The flip is
    ///   gated by `StoreKitIAPFlag` inside `setOnDevice`.
    /// - Parameter purchaseClosure: Test seam. Production callers pass `nil`
    ///   (default = `{ try await $0.purchase() }`). PurchaseServiceTests
    ///   injects closures returning `.userCancelled` or `.pending` because
    ///   SKTestSession cannot reliably synthesize those outcomes.
    @available(iOS 18.4, *)
    public init(
        productFetcher: any ProductFetching,
        verifier: any ReceiptVerifier,
        reconciler: EntitlementReconciler,
        purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)? = nil
    ) {
        self.productFetcher = productFetcher
        self.verifier = verifier
        self.reconciler = reconciler
        self.purchaseClosure = purchaseClosure ?? { product in try await product.purchase() }
    }

    // MARK: - Purchase entry point

    /// Initiate a purchase for the given product ID.
    ///
    /// UI calls `await purchaseService.purchase(productId: snapshot.id)` and
    /// renders the returned ``PurchaseOutcome``.
    public func purchase(productId: String) async throws -> PurchaseOutcome {
        guard let product = await productFetcher.rawProduct(for: productId) else {
            Log.event("iap.purchase.product_not_loaded", level: .warning,
                      data: ["productId": productId])
            throw PurchaseError.productNotLoaded(productId: productId)
        }

        let result: Product.PurchaseResult
        do {
            result = try await purchaseClosure(product)
        } catch {
            Log.event("iap.purchase.storekit_throw", level: .error,
                      data: ["error": String(describing: error)])
            throw PurchaseError.storeKit(String(describing: error))
        }

        switch result {
        case .success(let verification):
            return try await handleVerified(verification, productId: productId)
        case .userCancelled:
            Log.event("iap.purchase.cancelled", level: .info)
            return .cancelled
        case .pending:
            Log.event("iap.purchase.pending", level: .info)
            return .awaitingApproval
        @unknown default:
            Log.event("iap.purchase.unknown_result", level: .warning)
            return .cancelled
        }
    }

    // MARK: - Boot-time replay of unfinished transactions

    /// Walk `Transaction.unfinished` and try to verify + finish each.
    ///
    /// Called once at app launch from AppDependencies BEFORE the
    /// `TransactionListener` starts, so that any transaction whose worker
    /// verification failed last session gets a retry. Safe to re-call.
    public func replayUnfinished() async {
        for await result in Transaction.unfinished {
            await processUpdate(result, source: "unfinished")
        }
    }

    // MARK: - PurchaseUpdateForwarder

    /// Called by ``TransactionListener`` for each `Transaction.updates`
    /// event and by ``replayUnfinished()`` for each cached transaction.
    /// `source` is for log correlation only.
    public func processUpdate(_ result: VerificationResult<Transaction>, source: String) async {
        guard case .verified(let tx) = result else {
            Log.event("iap.update.unverified", level: .warning, data: ["source": source])
            return
        }
        // Skip if the same-session purchase path is already verifying this id.
        if inFlightTransactionIds.contains(tx.id) {
            Log.event("iap.update.skip_in_flight", level: .info,
                      data: ["tx": "\(tx.id)", "source": source])
            return
        }
        do {
            let resp = try await verifier.verify(
                jws: result.jwsRepresentation,
                productId: tx.productID,
                transactionId: tx.id
            )
            if resp.verified {
                await tx.finish()
                await MainActor.run { self.reconciler.setOnDevice(.subscribed) }
                Log.event("iap.update.granted_and_finished", level: .info,
                          data: ["tx": "\(tx.id)", "source": source])
            } else {
                // Worker rejected — finish to break the loop.
                await tx.finish()
                Log.event("iap.update.rejected_and_finished", level: .warning,
                          data: [
                              "tx": "\(tx.id)",
                              "reason": resp.reason ?? "unknown",
                              "source": source,
                          ])
            }
        } catch {
            // Transport failure — leave UNFINISHED for the next-launch replay.
            Log.event("iap.update.verify_threw_left_unfinished", level: .warning,
                      data: [
                          "tx": "\(tx.id)",
                          "error": String(describing: error),
                          "source": source,
                      ])
        }
    }

    // MARK: - Private

    private func handleVerified(
        _ result: VerificationResult<Transaction>,
        productId: String
    ) async throws -> PurchaseOutcome {
        let tx: Transaction
        do {
            tx = try result.payloadValue
        } catch {
            Log.event("iap.purchase.unverified", level: .error,
                      data: ["error": String(describing: error)])
            // Do NOT finish. Apple replays via Transaction.updates.
            throw PurchaseError.unverifiedReceipt
        }

        inFlightTransactionIds.insert(tx.id)
        defer { inFlightTransactionIds.remove(tx.id) }

        let resp: VerifyReceiptResponse
        do {
            resp = try await verifier.verify(
                jws: result.jwsRepresentation,
                productId: tx.productID,
                transactionId: tx.id
            )
        } catch {
            // Transport failure — leave UNFINISHED so Transaction.unfinished
            // replays on next launch (RESEARCH §3.3).
            Log.event("iap.purchase.worker_unreachable", level: .warning,
                      data: ["tx": "\(tx.id)", "error": String(describing: error)])
            throw PurchaseError.workerUnreachable(String(describing: error))
        }

        if resp.verified {
            await tx.finish()
            await MainActor.run { self.reconciler.setOnDevice(.subscribed) }
            Log.event("iap.purchase.granted", level: .info,
                      data: ["tx": "\(tx.id)", "productId": productId])
            return .granted(premiumUntil: resp.premiumUntil)
        } else {
            // Worker rejected — finish to break the loop; reconciler stays free.
            await tx.finish()
            Log.event("iap.purchase.worker_rejected", level: .warning,
                      data: ["tx": "\(tx.id)", "reason": resp.reason ?? "unknown"])
            return .rejected(reason: resp.reason ?? "unknown")
        }
    }
}

// MARK: - PurchaseProtocol conformance (plan 13-05)
//
// Adopted via extension so the public protocol seam is wired without
// editing the actor declaration line. PaywallViewModel + tests can take
// `any PurchaseProtocol`; production passes the concrete actor.
@available(iOS 18.4, *)
extension PurchaseService: PurchaseProtocol {}
