import Foundation
import StoreKit


/// Errors surfaced by ``StoreKitProductService/load()``.
public enum StoreKitProductLoadError: Error, Equatable, Sendable {
    /// `Product.products(for:)` threw or the underlying StoreKit machinery is
    /// not reachable. Wraps the original error as a description so the type
    /// stays `Equatable`.
    case storeKitUnavailable(String)
    /// StoreKit returned an empty product list — usually a misconfigured
    /// `.storekit` file or App Store Connect product setup.
    case noProductsReturned
    /// StoreKit returned products but the catalog is missing one of the
    /// expected Rishi Pro product IDs.
    case missingExpectedProduct(productId: String)
}

/// Loads Rishi Pro products from the local `.storekit` config (offline-sim)
/// and from App Store Connect (sandbox / production), exposes them as
/// `Sendable` ``ProductSnapshot`` values, and caches the last successful
/// load so repeat reads are zero-network.
///
/// **Concurrency model.** This is an `actor` (NOT `@MainActor`). Internal
/// mutation is actor-isolated; UI consumes snapshots via async accessors.
/// Per RESEARCH §10 Pitfall 14, the actor keeps raw `Product` instances
/// internally and only ever vends `Sendable` value types to MainActor
/// callers.
///
/// **Cache contract.** A failed reload does NOT clobber the cache — once
/// `load()` has succeeded, subsequent failures only update `lastLoadError`.
/// This means a user who was online during their last successful load can
/// still render the paywall from cache when offline.
//public actor StoreKitProductService {
//
//    // MARK: - Product IDs
//
//    public static let monthlyProductId = "org.fidexa.rishi.pro.monthly"
//    public static let annualProductId  = "org.fidexa.rishi.pro.annual"
//    public static let productIds: Set<String> = [monthlyProductId, annualProductId]
//
//    // MARK: - State
//
//    /// Raw StoreKit products keyed by productID. Stays inside the actor —
//    /// never crosses an isolation boundary in raw form.
//    private var rawProducts: [String: Product] = [:]
//    /// Last successfully-built catalog. Survives load failures.
//    private var cachedCatalog: ProductCatalog = .empty
//    /// Last error from ``load()``. `nil` after a successful load.
//    private var lastLoadError: StoreKitProductLoadError?
//
//    public init() {}
//
//    // MARK: - Load
//
//    /// Type alias for the loader closure used by the test-only seam.
//    public typealias Loader = @Sendable (Set<String>) async throws -> [Product]
//
//    /// Force a fresh load from StoreKit. Updates the cached snapshot on
//    /// success; records the error and leaves the cache untouched on failure.
//    @discardableResult
//    public func load() async throws -> ProductCatalog {
//        try await load(using: Self.defaultLoader)
//    }
//
//    /// Test-only seam that lets unit tests inject a throwing loader to
//    /// exercise the cache-survives-failure contract without driving a real
//    /// `Product.products(for:)` call to failure.
//    @discardableResult
//    func loadForTesting(using loader: @escaping Loader) async throws -> ProductCatalog {
//        try await load(using: loader)
//    }
//
//    private static let defaultLoader: Loader = { ids in
//        try await Product.products(for: ids)
//    }
//
//    private func load(using loader: Loader) async throws -> ProductCatalog {
//        do {
//            let products = try await loader(Self.productIds)
//            guard !products.isEmpty else {
//                self.lastLoadError = .noProductsReturned
//                Log.event("iap.products.empty", level: .warning)
//                throw StoreKitProductLoadError.noProductsReturned
//            }
//            var byId: [String: Product] = [:]
//            for p in products { byId[p.id] = p }
//            self.rawProducts = byId
//            self.cachedCatalog = await Self.buildCatalog(byId)
//            self.lastLoadError = nil
//            Log.event("iap.products.loaded", level: .info,
//                      data: ["count": "\(products.count)"])
//            return cachedCatalog
//        } catch let err as StoreKitProductLoadError {
//            // Already a typed error from the guard above (or rethrown by a
//            // test loader). Record on the cache but DO NOT clobber the
//            // previously-built snapshot — that is the cache-survives-failure
//            // contract relied on by offline-after-success.
//            self.lastLoadError = err
//            throw err
//        } catch {
//            let mapped = StoreKitProductLoadError.storeKitUnavailable(String(describing: error))
//            self.lastLoadError = mapped
//            Log.event("iap.products.load_failed", level: .error,
//                      data: ["error": String(describing: error)])
//            throw mapped
//        }
//    }
//
//    // MARK: - Accessors
//
//    /// Cached snapshot read for UI. Returns `.empty` if `load()` never
//    /// succeeded.
//    public func catalog() -> ProductCatalog { cachedCatalog }
//
//    /// Snapshot of the last load error, if any.
//    public func loadError() -> StoreKitProductLoadError? { lastLoadError }
//
//    /// Raw `Product` accessor for ``PurchaseService`` (Wave 1 plan 13-03).
//    /// Returns `nil` if the catalog has not been loaded or the productID is
//    /// unknown.
//    public func rawProduct(for productId: String) -> Product? {
//        rawProducts[productId]
//    }
//
//    // MARK: - Snapshot building
//
//    /// Build the `Sendable` catalog from raw products. `async` so it can
//    /// call `product.subscription?.isEligibleForIntroOffer` (which is async).
//    private static func buildCatalog(_ byId: [String: Product]) async -> ProductCatalog {
//        async let monthly = snapshot(for: byId[monthlyProductId])
//        async let annual  = snapshot(for: byId[annualProductId])
//        return ProductCatalog(monthly: await monthly, annual: await annual)
//    }
//
//    private static func snapshot(for product: Product?) async -> ProductSnapshot? {
//        guard let p = product, let sub = p.subscription else { return nil }
//        // `isEligibleForIntroOffer` is async on `Product.SubscriptionInfo`
//        // (RESEARCH §10 Pitfall 8). Non-throwing on current SDKs but the
//        // `await` is what we actually need; the value is `Bool`.
//        let eligible = await p.subscription?.isEligibleForIntroOffer ?? false
//        let unit: ProductSnapshot.Period = {
//            switch sub.subscriptionPeriod.unit {
//            case .day:   return .unknown
//            case .week:  return .week
//            case .month: return .month
//            case .year:  return .year
//            @unknown default: return .unknown
//            }
//        }()
//        // Manual localization rather than `Product.SubscriptionPeriod`
//        // FormatStyle (not available on every supported SDK). The plural
//        // word is wrapped against `value` so "1 month" / "3 months" render
//        // correctly when ASC pricing tiers move off P1M / P1Y.
//        let periodLocalized: String = {
//            let v = sub.subscriptionPeriod.value
//            switch sub.subscriptionPeriod.unit {
//            case .day:   return v == 1 ? "day"   : "\(v) days"
//            case .week:  return v == 1 ? "week"  : "\(v) weeks"
//            case .month: return v == 1 ? "month" : "\(v) months"
//            case .year:  return v == 1 ? "year"  : "\(v) years"
//            @unknown default: return ""
//            }
//        }()
//        let introDesc: String? = {
//            guard eligible,
//                  let offer = sub.introductoryOffer,
//                  offer.paymentMode == .freeTrial else { return nil }
//            let count = offer.period.value * offer.periodCount
//            let unitWord: String = {
//                switch offer.period.unit {
//                case .day:   return count == 1 ? "day"   : "days"
//                case .week:  return count == 1 ? "week"  : "weeks"
//                case .month: return count == 1 ? "month" : "months"
//                case .year:  return count == 1 ? "year"  : "years"
//                @unknown default: return ""
//                }
//            }()
//            return "\(count)-\(unitWord) free trial"
//        }()
//        return ProductSnapshot(
//            id: p.id,
//            displayName: p.displayName,
//            displayPrice: p.displayPrice,
//            period: unit,
//            periodLocalized: periodLocalized,
//            isEligibleForIntroOffer: eligible,
//            introOfferDescription: introDesc
//        )
//    }
//}

// MARK: - ProductFetching Conformance
//
// Moved into RishiBilling (owning module) in Phase 15 plan 15-04 to eliminate
// the Swift 6 retroactive-conformance warning. Both StoreKitProductService and
// ProductFetching are declared in this same module, so the conformance lives
// here structurally — no annotation needed. The protocol declaration lives in
// ReceiptVerifier.swift; the actor exposes the matching `rawProduct(for:)`
// accessor used by PurchaseService.
//extension StoreKitProductService: ProductFetching {}
