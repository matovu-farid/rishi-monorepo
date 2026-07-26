import Foundation
import StoreKit

// MARK: - Worker response

/// Worker's reply to `POST /api/billing/verify-receipt`.
///
/// `verified == true` means the worker accepted the JWS and persisted
/// `premium_until`. `verified == false` means the worker actively rejected
/// the receipt (replay / mismatch / signature invalid) and the caller
/// SHOULD finish the transaction to break the retry loop — the user does
/// NOT get the entitlement.
public struct VerifyReceiptResponse: Sendable, Equatable, Decodable {
    public let verified: Bool
    public let premiumUntil: Date?
    public let reason: String?

    public init(verified: Bool, premiumUntil: Date?, reason: String?) {
        self.verified = verified
        self.premiumUntil = premiumUntil
        self.reason = reason
    }
}

// MARK: - Verifier errors

/// Errors raised by ``ReceiptVerifier`` implementations.
///
/// `.network` means transport failure — the worker was unreachable. The
/// caller MUST leave the StoreKit transaction UNFINISHED so
/// `Transaction.unfinished` replays it on next launch.
///
/// `.rejected` is a structured payload variant of "worker said no" — most
/// implementations represent rejection via `VerifyReceiptResponse(verified: false, …)`
/// instead, but this case exists for verifiers that prefer to throw on
/// rejection (e.g. test stubs).
public enum VerifyReceiptError: Error, Equatable, Sendable {
    case network(String)
    case rejected(String)
}

// MARK: - Public protocol (promoted from Wave 0 Tests/Stubs/)

/// Verifies a signed StoreKit JWS receipt with the worker.
///
/// Wave 0 (plan 13-01) introduced the protocol in the test target's
/// `Stubs/` directory; Wave 1 (this plan, 13-03) promotes it into the
/// production module so `PurchaseService`, `TransactionListener`, and the
/// `WorkerReceiptVerifier` production implementation all share a single
/// public contract. `StubReceiptVerifier` was rewritten to re-import the
/// promoted protocol instead of redeclaring it locally.
///
/// Contract:
/// - Throws `VerifyReceiptError.network` on transport failure; caller MUST
///   leave the transaction UNFINISHED so `Transaction.unfinished` replays
///   on next launch (RESEARCH §3.3 worker-unreachable row).
/// - Returns `VerifyReceiptResponse(verified: false, …)` on active rejection
///   (replay / mismatch); caller finishes the transaction to break the loop.
/// - Returns `VerifyReceiptResponse(verified: true, premiumUntil: …)` on
///   success; caller finishes the transaction AND grants the entitlement.
public protocol ReceiptVerifier: Sendable {
    /// Verify a signed JWS receipt with the worker.
    func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse
}

// MARK: - Product fetching seam

/// Minimal product-fetching surface PurchaseService depends on. Plan 13-02
/// produces ``StoreKitProductService`` (sibling Wave 1 plan); that actor
/// adopts this protocol via an extension once both plans have landed, so
/// PurchaseService never has a hard compile-time dependency on the sibling
/// service. Tests can inject a single-product fetcher (see
/// ``PurchaseServiceTests/SingleProductFetcher``) without needing
/// StoreKitProductService at all.
public protocol ProductFetching: Sendable {
    /// Return the cached raw `Product` for the given product ID, or `nil`
    /// if the product has not been loaded.
    func rawProduct(for productId: String) async -> Product?
}
