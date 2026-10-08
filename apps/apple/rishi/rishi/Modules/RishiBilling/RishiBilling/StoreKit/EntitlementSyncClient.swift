import Foundation



/// Protocol seam so ``PurchaseService`` (and any future paywall code) can
/// be tested with a stub instead of a real ``WorkerClient``. Mirrors
/// ``ReceiptVerifier``'s existing seam shape.
public protocol EntitlementSyncing: Sendable {
    /// POST the transaction's JWS to `/api/billing/entitlement-sync`.
    /// Returns ``EntitlementSyncResult`` on successful HTTP (including
    /// business rejects with `verified: false`). Throws only on transport /
    /// server failure so callers can leave the StoreKit transaction
    /// unfinished for replay. Does not invoke ``EntitlementSyncHooks`` —
    /// the caller (``PurchaseService``) decides when to refresh.
    func sync(transactionJWS: String) async throws -> EntitlementSyncResult
}

/// Production ``EntitlementSyncing`` wrapping ``WorkerClient``. Follows
/// ``WorkerReceiptVerifier``'s DI shape (actor + injected `WorkerClient`).
public actor EntitlementSyncClient: EntitlementSyncing {
    private let client: WorkerClient

    public init(client: WorkerClient) {
        self.client = client
    }

    nonisolated func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool {
        client.usesCredentialAuthority(authority)
    }

    /// Original account admission survives the actor hop and every retry.
    func sync(transactionJWS: String, credentialContext: CredentialRequestContext) async throws -> EntitlementSyncResult {
        guard case .normal = credentialContext else { throw CredentialAuthenticationFailure.accountChanged }
        // Receipt sync commits a remote effect. Deliver late successful HTTP
        // to the original transaction finisher, without admitting another lease.
        let admitted = try await client.sendAdmittedCreation(
            EntitlementSyncEndpoint(body: .init(transactionJWS: transactionJWS)),
            credentialContext: credentialContext
        )
        return EntitlementSyncResult(verified: admitted.response.verified, reason: admitted.response.reason)
    }

    public func sync(transactionJWS: String) async throws -> EntitlementSyncResult {
        do {
            let response = try await client.send(
                EntitlementSyncEndpoint(body: .init(transactionJWS: transactionJWS))
            )
            Log.event("iap.entitlement_sync.done", level: .info,
                      data: ["verified": "\(response.verified)"])
            return EntitlementSyncResult(
                verified: response.verified,
                reason: response.reason
            )
        } catch {
            Log.event("iap.entitlement_sync.failed", level: .warning,
                      data: ["error": String(describing: error)])
            throw error
        }
    }
}
