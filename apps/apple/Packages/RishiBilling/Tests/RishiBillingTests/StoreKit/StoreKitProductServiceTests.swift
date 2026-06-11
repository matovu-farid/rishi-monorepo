import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import RishiBilling

/// Compile-time Sendable check helper. If the type is not Sendable, the
/// `acceptsSendable(snap)` call fails to compile under Swift 6 strict.
private func acceptsSendable<T: Sendable>(_ value: T) {}

@Suite(.serialized)
struct StoreKitProductServiceTests {

    let session: SKTestSession

    init() throws {
        let s = try SKTestSession(configurationFileNamed: "Rishi")
        s.disableDialogs = true
        s.clearTransactions()
        // Reset eligibility for intro offer so freshly-cleared session always
        // reports `isEligibleForIntroOffer == true`.
        s.resetToDefaultState()
        self.session = s
    }

    // MARK: - load() catalog

    @Test func loadReturnsCatalogWithBothTiers() async throws {
        let service = StoreKitProductService()
        let catalog = try await service.load()
        #expect(catalog.monthly?.id == StoreKitProductService.monthlyProductId)
        #expect(catalog.annual?.id  == StoreKitProductService.annualProductId)
        #expect(catalog.hasAny == true)
    }

    @Test func loadSetsDisplayPriceFromStoreKitConfig() async throws {
        let service = StoreKitProductService()
        let catalog = try await service.load()
        // SKTestSession pinned to _storefront=USA, _locale=en_US in Rishi.storekit
        // so prices localize as "$4.99" / "$39.99". Use substring on the
        // numeric portion to avoid host-locale flakiness when the storefront
        // override isn't honoured.
        #expect(catalog.monthly?.displayPrice.contains("4.99") == true,
                "monthly displayPrice was \(catalog.monthly?.displayPrice ?? "nil")")
        #expect(catalog.annual?.displayPrice.contains("39.99") == true,
                "annual displayPrice was \(catalog.annual?.displayPrice ?? "nil")")
    }

    @Test func loadSetsPeriod() async throws {
        let service = StoreKitProductService()
        let catalog = try await service.load()
        #expect(catalog.monthly?.period == .month)
        #expect(catalog.annual?.period == .year)
    }

    @Test func loadIntroOfferEligibleOnFreshSession() async throws {
        let service = StoreKitProductService()
        let catalog = try await service.load()
        // Freshly-cleared SKTestSession: user is always eligible for the
        // 7-day P1W intro free trial declared in Rishi.storekit.
        #expect(catalog.monthly?.isEligibleForIntroOffer == true)
        #expect(catalog.annual?.isEligibleForIntroOffer == true)
        let monthlyDesc = catalog.monthly?.introOfferDescription ?? ""
        #expect(monthlyDesc.contains("free trial"),
                "monthly intro desc was \(monthlyDesc)")
        // P1W maps to either "7-day free trial" or "1-week free trial"
        // depending on how Apple formats the offer period in the test session.
        #expect(monthlyDesc.contains("7") || monthlyDesc.contains("week"),
                "monthly intro desc was \(monthlyDesc)")
    }

    // MARK: - catalog() snapshot

    @Test func catalogEmptyBeforeLoad() async {
        let service = StoreKitProductService()
        let catalog = await service.catalog()
        #expect(catalog == .empty)
        #expect(catalog.hasAny == false)
    }

    @Test func catalogReturnsCachedAfterLoad() async throws {
        let service = StoreKitProductService()
        _ = try await service.load()
        let first = await service.catalog()
        let second = await service.catalog()
        #expect(first == second)
        #expect(first.monthly?.id == StoreKitProductService.monthlyProductId)
    }

    // MARK: - rawProduct(for:)

    @Test func rawProductReturnsProductForKnownId() async throws {
        let service = StoreKitProductService()
        _ = try await service.load()
        let monthly = await service.rawProduct(for: StoreKitProductService.monthlyProductId)
        let annual  = await service.rawProduct(for: StoreKitProductService.annualProductId)
        #expect(monthly != nil)
        #expect(annual != nil)
        #expect(monthly?.id == StoreKitProductService.monthlyProductId)
    }

    @Test func rawProductReturnsNilForUnknownId() async throws {
        let service = StoreKitProductService()
        _ = try await service.load()
        let unknown = await service.rawProduct(for: "org.fidexa.rishi.pro.lifetime")
        #expect(unknown == nil)
    }

    // MARK: - cache survives failure

    @Test func loadFailureDoesNotClobberCache() async throws {
        let service = StoreKitProductService()
        let successful = try await service.load()
        #expect(successful.hasAny == true)
        // Synthesize a failure by injecting a throwing loader via the
        // test-only seam. Cached catalog must remain populated.
        await #expect(throws: StoreKitProductLoadError.self) {
            _ = try await service.loadForTesting { _ in
                throw StoreKitProductLoadError.noProductsReturned
            }
        }
        let afterFailure = await service.catalog()
        #expect(afterFailure == successful,
                "cache was clobbered after failed reload")
    }

    // MARK: - Sendable conformance

    @Test func productSnapshotIsSendable() {
        let snap = ProductSnapshot(
            id: "x",
            displayName: "x",
            displayPrice: "$0",
            period: .month,
            periodLocalized: "month",
            isEligibleForIntroOffer: false,
            introOfferDescription: nil
        )
        // Compile-time proof that ProductSnapshot is Sendable.
        acceptsSendable(snap)
        // And ProductCatalog too — UI binds to it on MainActor.
        let catalog = ProductCatalog(monthly: snap, annual: nil)
        acceptsSendable(catalog)
    }
}
