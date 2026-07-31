






import Foundation



import OSLog
import StoreKit

private let logger = Logger(subsystem: "Rishi", category: "CustomerEntitlements")
import Foundation

public typealias SubscriptionGroupID = String


@available(iOS 18.4, macOS 15.4, *)
@MainActor @Observable
public final class CustomerEntitlements {
    
    private var transactionUpdatesTask: Task<Void, any Error>?
    private var statusUpdatesTask: Task<Void, any Error>?
    private var inFlightTransactionIds: Set<UInt64> = []
    
    isolated deinit {
        transactionUpdatesTask?.cancel()
        statusUpdatesTask?.cancel()
    }
    
    
    
    public static let shared: CustomerEntitlements = .init()
    
    public private(set) var ownedNonConsumables: Set<Product.ID> = []
    
    public private(set) var subscriptionStatuses: [SubscriptionGroupID: [SubscriptionStatus]] = [:]
    
    public private(set) var error: CustomerEntitlementsError?

    /// Returns whether StoreKit currently reports an active subscription in
    /// the supplied group, including grace-period and billing-retry states.
    public func hasActiveSubscription(in groupID: SubscriptionGroupID) -> Bool {
        subscriptionStatuses[groupID]?.activeSubscriptionStatuses.isEmpty == false
    }

    /// The product currently active in a subscription group, if StoreKit has
    /// reported current status for that group.
    public func activeProductID(in groupID: SubscriptionGroupID) -> Product.ID? {
        subscriptionStatuses[groupID]?.activeSubscriptionStatuses
            .sorted { $0.transaction.unsafePayloadValue.purchaseDate > $1.transaction.unsafePayloadValue.purchaseDate }
            .first?
            .transaction
            .unsafePayloadValue
            .productID
    }
    
    /// Sync entitlement with the worker, then finish on any successful HTTP
    /// (verified or business reject). On transport failure the transaction
    /// is left unfinished so `Transaction.unfinished` / `Transaction.updates`
    /// can retry. Snapshot refresh runs via ``EntitlementSyncHooks/onSynced``
    /// only when the worker reports `verified: true`.
    ///
    /// User-facing `.entitlementSyncFailed` is only set for
    /// ``EntitlementProcessOrigin/purchaseCompletion``. Background paths
    /// (paywall open / unfinished replay) log rejects without alerting —
    /// StoreKit Testing JWTs commonly fail Apple-root worker verify.
    public func process(
        transaction: Transaction,
        jws: String,
        origin: EntitlementProcessOrigin = .backgroundSync
    ) async {
        if inFlightTransactionIds.contains(transaction.id) {
            logger.debug("""
            Skipping duplicate process for in-flight transaction \(transaction.id)
            """)
            return
        }
        inFlightTransactionIds.insert(transaction.id)
        defer { inFlightTransactionIds.remove(transaction.id) }

        do {
            let result = try await syncEntitlement(jws: jws)
            await transaction.finish()
            if result.verified {
                logger.debug("""
                Finished transaction \(transaction.id) after successful entitlement sync
                """)
            } else {
                logger.error("""
                Entitlement sync rejected transaction \(transaction.id) \
                (\(transaction.productID)); reason: \(result.reason ?? "unknown")
                """)
                if shouldSurfaceEntitlementSyncFailure(
                    origin: origin,
                    transaction: transaction
                ) {
                    updateError(.entitlementSyncFailed)
                }
            }
        } catch {
            logger.error("""
            Entitlement sync failed for transaction \(transaction.id) \
            (\(transaction.productID)); leaving unfinished for replay: \(error)
            """)
            if shouldSurfaceEntitlementSyncFailure(
                origin: origin,
                transaction: transaction
            ) {
                updateError(.entitlementSyncFailed)
            }
        }
    }

    /// Surface sync rejects only for a real purchase attempt that is not
    /// StoreKit Testing (Xcode). Xcode rejects are expected until/unless the
    /// non-prod worker accepts StoreKit Testing JWTs.
    private func shouldSurfaceEntitlementSyncFailure(
        origin: EntitlementProcessOrigin,
        transaction: Transaction
    ) -> Bool {
        guard origin == .purchaseCompletion else { return false }
        if transaction.environment == .xcode { return false }
        return true
    }
    

    
    
    public func observeTransactionUpdates() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = Task { [weak self] in
            logger.debug("Observing transaction updates")
            for await update in Transaction.updates {
                guard let self else { return }
                guard let transaction = await unwrapVerificationResult(update) else { continue }
             
               
            
                await self.process(
                    transaction: transaction,
                    jws: update.jwsRepresentation,
                    origin: .purchaseCompletion
                )
                
                do {
                   let _ = try await VerifyEndPont(body: .init(transactionId: transaction.id)).send()
                }catch {
                    print(error)
                }
             
            }
        }
    }
    
    public func checkForCurrentEntitlements() async {
        logger.debug("Checking for current entitlements")
        for await result in Transaction.currentEntitlements {
            guard let transaction = await unwrapVerificationResult(result) else {
                logger.error("Encountered error while checking for current entitlements")
                return
            }
            logger.log("""
            Processing current entitlement \(transaction.id) for \
            \(transaction.productID)
            """)
//            SubscriptionService.shared.saveSubscription(subscription: .subscribed)
            let jws = result.jwsRepresentation
            Task.detached(priority: .background) {
                await self.process(transaction: transaction, jws: jws)
                
            }
        }
        logger.debug("Finished checking for current entitlements")
    }
    
    public func checkForUnfinishedTransactions() async {
        logger.debug("Checking for unfinished transactions")
        for await result in Transaction.unfinished {
            guard let transaction = await unwrapVerificationResult(result) else {
                logger.error("Encountered error while checking for unfinished transactions")
                return
            }
            logger.log("""
            Processing unfinished transaction ID \(transaction.id) for \
            \(transaction.productID)
            """)
            let jws = result.jwsRepresentation
            Task.detached(priority: .background) {
                await self.process(transaction: transaction, jws: jws)
            }
        }
        logger.debug("Finished checking for unfinished transactions")
    }
    
    
    
    public func observeStatusUpdates() {
        statusUpdatesTask?.cancel()
        statusUpdatesTask = Task { [weak self] in
            logger.debug("Observing status updates")
            for await status in SubscriptionStatus.updates {
                guard let self,
                      let transaction = await unwrapVerificationResult(status.transaction),
                      let subscriptionGroupID = transaction.subscriptionGroupID
                else {
                    continue
                }
                
                let updatedStatuses: [SubscriptionStatus]
                let currentStatuses = self.subscriptionStatuses[subscriptionGroupID]
                if let currentStatuses {
                    if let currentStatus = currentStatuses.first(where: {
                        $0.transaction.unsafePayloadValue.ownershipType == transaction.ownershipType
                    }) {
                        updatedStatuses = currentStatuses.filter { $0 != currentStatus } + [status]
                    } else {
                        updatedStatuses = currentStatuses + [status]
                    }
                } else {
                    updatedStatuses = [status]
                }
                
                self.updateSubscriptionStatuses(for: subscriptionGroupID, statuses: updatedStatuses)
            }
        }
    }
    
    public func checkCurrentStatuses() async {
        logger.debug("Checking current statuses")
        for await (subscriptionGroupID, statuses) in SubscriptionStatus.all {
            updateSubscriptionStatuses(for: subscriptionGroupID, statuses: statuses)
        }
        logger.debug("Finished checking current statuses")
    }
    
    
    
 
    private func unwrapVerificationResult(
        _ verificationResult: VerificationResult<Transaction>
    ) async -> Transaction? {
        
        
        switch verificationResult {
        case .verified(let t):
            logger.debug("""
            Transaction ID \(t.id) for \(t.productID) is verified
            """)
            return t
        case .unverified(let t, let error):
            
            logger.error("""
            Transaction ID \(t.id) for \(t.productID) is unverified: \(error)
            """)
            updateError(.invalidTransaction)
            return nil
        }
    }
    

    private func updateSubscriptionStatuses(for subscriptionGroupID: String, statuses: [SubscriptionStatus]) {
        self.subscriptionStatuses[subscriptionGroupID] = statuses
    }
    
    private func updateError(_ error: CustomerEntitlementsError) {
        self.error = error
    }
}

/// Why ``CustomerEntitlements/process(transaction:jws:origin:)`` was invoked.
/// Controls whether a failed sync surfaces a user-facing error.
public enum EntitlementProcessOrigin: Sendable {
    /// Same-session purchase completion, including `Transaction.updates`
    /// for live purchase / Ask-to-Buy resolution.
    case purchaseCompletion
    /// `Transaction.currentEntitlements` or `Transaction.unfinished` replay.
    case backgroundSync
}

public enum CustomerEntitlementsError: Error, Equatable {
    case invalidTransaction
    case failedToFetchPersistedData
    case failedToUpdatePersistedData
    /// Worker entitlement-sync failed (transport) or returned verified:false
    /// (business reject). Transport leaves the transaction unfinished;
    /// verified:false finishes it (unretriable for this JWS).
    case entitlementSyncFailed
}


@available(iOS 18.4, macOS 15.4, *)
extension Sequence where Element == SubscriptionStatus {
    public var activeSubscriptionStatuses: [SubscriptionStatus] {
        filter {
            $0.state == .subscribed || $0.state == .inGracePeriod || $0.state == .inBillingRetryPeriod
        }
    }
    
    public var highestSubscriptionStatus: SubscriptionStatus? {
        get throws {

            return self.first(where: {
                EntitlementLevel.initialize(productId: $0.transaction.unsafePayloadValue.productID) == .subscribed

            })
        }
    }
    
 
}
