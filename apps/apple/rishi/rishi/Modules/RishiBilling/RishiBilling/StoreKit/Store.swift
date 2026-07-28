


import OSLog
import StoreKit

private let logger = Logger(subsystem: "Rishi", category: "Store")

typealias ProductID = String

func fetchProductIDs()->[ProductID]{
    return RishiProductID.currentPlatformProductIDs
}

@available(iOS 18.4, macOS 15.4, *)
@MainActor @Observable
public final class Store {
    public static let shared: Store = .init()

    public private(set) var products: [Product] = []
    public private(set) var loadState: StoreLoadState = .idle

    public private(set) var error: StoreError?

    private let productLoader: @Sendable ([String]) async throws -> [Product]
    private(set) var retryID = 0

    public init(productLoader: @escaping @Sendable ([String]) async throws -> [Product] = { ids in
        try await Product.products(for: ids)
    }) {
        self.productLoader = productLoader
    }

    public var hasCompleteCurrentPlatformCatalog: Bool {
        Self.isCompleteCatalog(
            returnedIDs: products.map(\.id),
            requestedIDs: fetchProductIDs()
        )
    }

    public static func isCompleteCatalog(returnedIDs: [String], requestedIDs: [String]) -> Bool {
        !requestedIDs.isEmpty
            && returnedIDs.count == requestedIDs.count
            && Set(returnedIDs) == Set(requestedIDs)
    }

    public static func catalogError(
        returnedIDs: [String],
        requestedIDs: [String]
    ) -> StoreError {
        returnedIDs.isEmpty ? .emptyProductCatalog : .incompleteProductCatalog
    }

    public func loadProducts() async {
        loadState = .loading
        products = []
        error = nil
        retryID &+= 1

        let productIDs = fetchProductIDs()
        do {
            let products = try await productLoader(productIDs)
            let productIDSet = Set(productIDs)
            let filteredProducts = products.filter { productIDSet.contains($0.id) }
            guard Self.isCompleteCatalog(
                returnedIDs: filteredProducts.map(\.id),
                requestedIDs: productIDs
            ) else {
                throw Self.catalogError(
                    returnedIDs: filteredProducts.map(\.id),
                    requestedIDs: productIDs
                )
            }
            self.products = productIDs.compactMap { id in
                filteredProducts.first { $0.id == id }
            }
            loadState = .loaded
        } catch {
            products = []
            self.error = error as? StoreError ?? .productRequestFailed
            loadState = .failed
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

            await CustomerEntitlements.shared.process(
                transaction: transaction,
                jws: verificationResult.jwsRepresentation,
                origin: .purchaseCompletion
            )
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
    case productRequestFailed
    case emptyProductCatalog
    case incompleteProductCatalog
}

public enum StoreLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

@available(iOS 18.4, macOS 15.4, *)
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
