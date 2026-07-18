import Foundation
import RishiCore
import RishiLogging

/// Protocol seam so ``PurchaseService`` (and any future paywall code) can
/// be tested with a stub instead of a real ``WorkerClient``. Mirrors
/// ``ReceiptVerifier``'s existing seam shape.
public protocol EntitlementSyncing: Sendable {
    /// POST the transaction's JWS to `/api/billing/entitlement-sync`.
    /// Throws on transport / server failure so callers can leave the
    /// StoreKit transaction unfinished for replay. Callers that already
    /// decided to finish (e.g. permanent worker reject) may catch and log.
    func sync(transactionJWS: String) async throws
}

/// Production ``EntitlementSyncing`` wrapping ``WorkerClient``. Follows
/// ``WorkerReceiptVerifier``'s DI shape (actor + injected `WorkerClient`).
public actor EntitlementSyncClient: EntitlementSyncing {
    private let client: WorkerClient

    public init(client: WorkerClient) {
        self.client = client
    }

    public func sync(transactionJWS: String) async throws {
        do {
            let response = try await client.send(
                EntitlementSyncEndpoint(body: .init(transactionJWS: transactionJWS))
            )
            Log.event("iap.entitlement_sync.done", level: .info,
                      data: ["verified": "\(response.verified)"])
        } catch {
            Log.event("iap.entitlement_sync.failed", level: .warning,
                      data: ["error": String(describing: error)])
            throw error
        }
    }
}
