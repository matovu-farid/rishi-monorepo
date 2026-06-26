


import OSLog
import StoreKit

private let logger = Logger(subsystem: "Rishi", category: "Store")

typealias ProductID = String

func fetchProductIDs()->[ProductID]{
    return ["org.fidexa.rishi.pro.monthly","org.fidexa.rishi.pro.annual"]
}

@available(iOS 18.4, *)
@MainActor @Observable
public final class Store {
    public static let shared: Store = .init()

    public private(set) var products: [Product] = []

    public private(set) var error: StoreError?

    public func loadProducts() async {
        do {
            
            let productIDs =  fetchProductIDs()
            let products = try await Product.products(for: productIDs)
            self.products = products
        } catch {
            logger.error("Failed product request from the App Store. \(error)")
        }
    }

    public func process(purchaseResult: sending Product.PurchaseResult) async {
        switch purchaseResult {
        case .success(let verificationResult):
            let unsafeTransaction = verificationResult.unsafePayloadValue
            logger.log("""
            Processing transaction ID \(unsafeTransaction.id) for \(unsafeTransaction.productID)
            """)

            let transaction: Transaction
            
            switch verificationResult {
            case .verified(let t):
                
                logger.debug("""
                Transaction ID \(t.id) for \(t.productID) is verified
                """)
                transaction = t
            case .unverified(let t, let error):
                
                
                logger.error("""
                Transaction ID \(t.id) for \(t.productID) is unverified: \(error)
                """)
                updateError(.invalidTransaction)
                return
            }

            await CustomerEntitlements.shared.process(transaction: transaction)
        case .pending:
            logger.debug("Pending")
            return
        case .userCancelled:
       
            logger.debug("User Cancelled")
            return
         default:
            logger.debug("Unknown process state")
            
            return
        }
  
        
    }

    private func updateError(_ error: StoreError) {
        self.error = error
    }
}

public enum StoreError: Error, Equatable {
    case invalidTransaction
}

@available(iOS 18.4, *)
extension Store {
   


    var annualSubscriptions: [Product] {
        products
            .filter { $0.subscription?.subscriptionPeriod.unit == .year }
            .sorted { $0.price < $1.price }
    }
    var monthlySubscriptions: [Product] {
        products
            .filter { $0.subscription?.subscriptionPeriod.unit == .month }
            .sorted { $0.price < $1.price }
    }


}
