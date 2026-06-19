import Foundation
import Observation
import RishiLogging

/// View-model orchestrating the Wave-3 paywall (plan 13-05).
///
/// Pulls products from ``StoreKitProductService`` (13-02), drives
/// purchases through ``PurchaseProtocol`` (13-03 / extracted in 13-05),
/// restores through ``RestoreProtocol`` (13-06 / extracted in 13-05),
/// and shows the system Manage Subscriptions sheet through
/// ``ManageSubscriptionPresenter`` (13-07).
///
/// `@MainActor @Observable` — SwiftUI binds directly. Observation
/// propagates ``loadState`` / ``purchaseState`` / ``restoreInFlight`` /
/// ``selectedTier`` changes to consumers.
@MainActor
@Observable
public final class PaywallViewModel {

    // MARK: - Public types

    /// Subscription tier the user can select from the paywall.
    public enum Tier: Sendable, Equatable {
        case monthly
        case annual

        /// Product ID matching the StoreKit configuration + App Store Connect.
        public var productId: String {
            switch self {
            case .monthly: return StoreKitProductService.monthlyProductId
            case .annual:  return StoreKitProductService.annualProductId
            }
        }
    }

    /// State of the active purchase / restore call. The paywall renders
    /// buttons + alerts off this.
    public enum PurchaseState: Sendable, Equatable {
        case idle
        case purchasing
        case succeeded
        case failed(String)
        case cancelled
        case awaitingApproval
    }

    /// Product-load lifecycle for the tier selector.
    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded(ProductCatalog)
        case failed(String)
    }

    // MARK: - Observable state

    public private(set) var loadState: LoadState = .idle
    public private(set) var purchaseState: PurchaseState = .idle
    public private(set) var restoreInFlight: Bool = false

    /// Default to annual — better unit economics, common pattern, matches
    /// the RESEARCH §5 hand-rolled blueprint.
    public var selectedTier: Tier = .annual

    // MARK: - Dependencies (constructor-injected)

    private let productService: StoreKitProductService
    private let purchaseService: any PurchaseProtocol
    private let restoreService: any RestoreProtocol
    private let managePresenter: ManageSubscriptionPresenter

    public init(productService: StoreKitProductService,
                purchaseService: any PurchaseProtocol,
                restoreService: any RestoreProtocol,
                managePresenter: ManageSubscriptionPresenter) {
        self.productService = productService
        self.purchaseService = purchaseService
        self.restoreService = restoreService
        self.managePresenter = managePresenter
    }

    // MARK: - Intent

    /// Called from the paywall's `.task` modifier on first appearance.
    public func onAppear() async {
        await loadProducts()
    }

    /// Force a product reload. Updates ``loadState`` to `.loading`, then
    /// `.loaded(catalog)` or `.failed(message)`.
    public func loadProducts() async {
        loadState = .loading
        do {
            let catalog = try await productService.load()
            loadState = .loaded(catalog)
        } catch {
            Log.event("iap.paywall.load_failed",
                      level: .error,
                      data: ["error": String(describing: error)])
            loadState = .failed(String(describing: error))
        }
    }

    /// Subscribe to the currently-selected tier.
    public func subscribe() async {
        purchaseState = .purchasing
        do {
            let outcome = try await purchaseService.purchase(
                productId: selectedTier.productId
            )
            switch outcome {
            case .granted:
                purchaseState = .succeeded
            case .cancelled:
                purchaseState = .cancelled
            case .awaitingApproval:
                purchaseState = .awaitingApproval
            case .rejected(let reason):
                purchaseState = .failed(reason)
            }
        } catch {
            Log.event("iap.paywall.subscribe_failed",
                      level: .error,
                      data: ["error": String(describing: error)])
            purchaseState = .failed(String(describing: error))
        }
    }

    /// Run the user-initiated restore. ``restoreInFlight`` toggles to
    /// `true` for the duration of the call so the paywall's Restore
    /// button can show a progress indicator.
    public func restore() async {
        restoreInFlight = true
        defer { restoreInFlight = false }
        do {
            let outcome = try await restoreService.restore()
            switch outcome {
            case .restored:
                purchaseState = .succeeded
            case .nothingToRestore:
                purchaseState = .failed(
                    "No purchases to restore on this Apple ID."
                )
            }
        } catch {
            Log.event("iap.paywall.restore_failed",
                      level: .error,
                      data: ["error": String(describing: error)])
            purchaseState = .failed(String(describing: error))
        }
    }

    /// Drive the `ManageSubscriptionPresenter`. Errors are absorbed by
    /// the presenter (`lastError`) — the VM does not surface them.
    public func openManageSubscriptions() async {
        await managePresenter.present()
    }

    // MARK: - Derived

    /// The snapshot for the currently-selected tier, or `nil` if products
    /// haven't loaded or the selected tier is missing from the catalog.
    public var selectedSnapshot: ProductSnapshot? {
        guard case .loaded(let catalog) = loadState else { return nil }
        switch selectedTier {
        case .monthly: return catalog.monthly
        case .annual:  return catalog.annual
        }
    }

    /// Title for the primary CTA. Trial-forward when the selected tier is
    /// eligible for an introductory free-trial offer; otherwise the neutral
    /// "Subscribe". Eligibility is per-Apple-ID (StoreKit reports it via
    /// `ProductSnapshot.isEligibleForIntroOffer`), so a user who already used
    /// the trial correctly sees "Subscribe" rather than misleading copy.
    public var subscribeCTATitle: String {
        if selectedSnapshot?.isEligibleForIntroOffer == true {
            return "Start Free Trial"
        }
        return "Subscribe"
    }

    // MARK: - Test seams

    /// Inject a `LoadState` directly. The production setter is `private(set)`
    /// so the only way to drive `.loaded(catalog)` is through `loadProducts()`,
    /// which requires a reachable StoreKit daemon. This internal seam lets
    /// unit tests place a known catalog into the view model to exercise the
    /// derived `selectedSnapshot` / `subscribeCTATitle` properties without
    /// the daemon.
    func setLoadStateForTesting(_ state: LoadState) {
        loadState = state
    }
}
