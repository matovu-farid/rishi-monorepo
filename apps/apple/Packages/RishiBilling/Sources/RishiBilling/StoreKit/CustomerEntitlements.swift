






import Foundation
import RishiCore


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
    
    isolated deinit {
        transactionUpdatesTask?.cancel()
        statusUpdatesTask?.cancel()
    }
    
    
    
    public static let shared: CustomerEntitlements = .init()
    
    public private(set) var ownedNonConsumables: Set<Product.ID> = []
    
    public private(set) var subscriptionStatuses: [SubscriptionGroupID: [SubscriptionStatus]] = [:]
    
    public private(set) var error: CustomerEntitlementsError?
    
    /// Sync entitlement with the worker, then finish. On sync failure the
    /// transaction is left unfinished so `Transaction.unfinished` /
    /// `Transaction.updates` can retry. Snapshot refresh runs via
    /// ``EntitlementSyncHooks/onSynced`` after a successful POST.
    public func process(transaction: Transaction, jws: String) async {
        do {
            try await syncEntitlement(jws: jws)
            await transaction.finish()
            logger.debug("""
            Finished transaction \(transaction.id) after successful entitlement sync
            """)
        } catch {
            logger.error("""
            Entitlement sync failed for transaction \(transaction.id) \
            (\(transaction.productID)); leaving unfinished for replay: \(error)
            """)
            updateError(.entitlementSyncFailed)
        }
    }
    

    
    
    public func observeTransactionUpdates() {
        transactionUpdatesTask = Task { [weak self] in
            logger.debug("Observing transaction updates")
            for await update in Transaction.updates {
                guard let self else { return }
                guard let transaction = await unwrapVerificationResult(update) else { continue }
             
               
            
                await self.process(transaction: transaction, jws: update.jwsRepresentation)
                
                do {
                    try await VerifyEndPont(body: .init(transactionId: transaction.id)).send()
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

public enum CustomerEntitlementsError: Error, Equatable {
    case invalidTransaction
    case failedToFetchPersistedData
    case failedToUpdatePersistedData
    /// Worker entitlement-sync POST failed; transaction left unfinished.
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
