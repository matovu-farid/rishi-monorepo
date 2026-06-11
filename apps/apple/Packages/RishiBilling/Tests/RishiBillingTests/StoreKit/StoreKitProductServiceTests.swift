import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import RishiBilling

/// Compile-time Sendable check helper. If the type is not Sendable, the
/// `acceptsSendable(snap)` call fails to compile under Swift 6 strict.
private func acceptsSendable<T: Sendable>(_ value: T) {}

/// Tests for ``StoreKitProductService``.
///
/// `@Suite(.serialized)` because `SKTestSession` mutates shared device
/// state. Same pattern as Phase 3 `SiwaFlowTests`.
///
/// **Host environment.** `SKTestSession` requires the StoreKit Testing
/// daemon (the `ASDErrorDomain Code=650 / Code=509` cluster otherwise).
/// On iOS simulator / `xcodebuild test` destinations the daemon is
/// available; under `swift test` on a Mac host it is NOT — products fail
/// to load with `noProductsReturned`. Tests that strictly require live
/// SKTestSession products are guarded by ``hasLiveStoreKitTestDaemon`` and
/// emit a `withKnownIssue` when the daemon is unavailable. The cache /
/// Sendable / injected-loader tests run unconditionally because they do
/// NOT depend on the daemon — they drive `loadForTesting(using:)` directly.
@Suite(.serialized)
struct StoreKitProductServiceTests {

    let session: SKTestSession

    init() throws {
        // Resolve the .storekit URL from the test resource bundle. The
        // Bundle-less SKTestSession initialiser only looks in `Bundle.main`,
        // which under `swift test` is the xctest harness — not where our
        // Resources/Rishi.storekit lives.
        guard let url = Bundle.module.url(forResource: "Rishi", withExtension: "storekit") else {
            Issue.record("Rishi.storekit missing from test bundle")
            throw StoreKitTestSetupError.missingConfig
        }
        let s = try SKTestSession(contentsOf: url)
        s.disableDialogs = true
        s.clearTransactions()
        s.resetToDefaultState()
        self.session = s
    }

    private enum StoreKitTestSetupError: Error { case missingConfig }

    /// Probes `Product.products(for:)` to detect whether the StoreKit Test
    /// daemon is reachable on the current host. Returns `true` when at
    /// least one product comes back — daemon present and serving. `false`
    /// otherwise (typical for `swift test` on macOS where the daemon isn't
    /// running, surfaces as `ASDErrorDomain Code=650`).
    private func probeStoreKitTestDaemon() async -> Bool {
        let probe = (try? await Product.products(for: [
            StoreKitProductService.monthlyProductId
        ])) ?? []
        return !probe.isEmpty
    }

    // MARK: - load() catalog (SKTestSession-dependent)

    @Test func loadReturnsCatalogWithBothTiers() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            let catalog = try await service.load()
            #expect(catalog.monthly?.id == StoreKitProductService.monthlyProductId)
            #expect(catalog.annual?.id  == StoreKitProductService.annualProductId)
            #expect(catalog.hasAny == true)
        }
    }

    @Test func loadSetsDisplayPriceFromStoreKitConfig() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            let catalog = try await service.load()
            // SKTestSession pinned to _storefront=USA, _locale=en_US so prices
            // localize as "$4.99" / "$39.99". Substring match on the numeric
            // portion tolerates host-locale variance.
            #expect(catalog.monthly?.displayPrice.contains("4.99") == true,
                    "monthly displayPrice was \(catalog.monthly?.displayPrice ?? "nil")")
            #expect(catalog.annual?.displayPrice.contains("39.99") == true,
                    "annual displayPrice was \(catalog.annual?.displayPrice ?? "nil")")
        }
    }

    @Test func loadSetsPeriod() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            let catalog = try await service.load()
            #expect(catalog.monthly?.period == .month)
            #expect(catalog.annual?.period == .year)
        }
    }

    @Test func loadIntroOfferEligibleOnFreshSession() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            let catalog = try await service.load()
            #expect(catalog.monthly?.isEligibleForIntroOffer == true)
            #expect(catalog.annual?.isEligibleForIntroOffer == true)
            let monthlyDesc = catalog.monthly?.introOfferDescription ?? ""
            #expect(monthlyDesc.contains("free trial"),
                    "monthly intro desc was \(monthlyDesc)")
            // P1W maps to "7-day free trial" or "1-week free trial" depending
            // on how the host renders the offer period — substring on either
            // form.
            #expect(monthlyDesc.contains("7") || monthlyDesc.contains("week"),
                    "monthly intro desc was \(monthlyDesc)")
        }
    }

    // MARK: - catalog() snapshot (no daemon required)

    @Test func catalogEmptyBeforeLoad() async {
        let service = StoreKitProductService()
        let catalog = await service.catalog()
        #expect(catalog == .empty)
        #expect(catalog.hasAny == false)
    }

    @Test func rawProductReturnsNilForUnknownIdAfterFailedInjectedLoad() async {
        let service = StoreKitProductService()
        // Force a failed load — cache stays `.empty`.
        do {
            _ = try await service.loadForTesting { _ in [] }
            Issue.record("expected noProductsReturned")
        } catch {
            // expected
        }
        let unknown = await service.rawProduct(for: "org.fidexa.rishi.pro.lifetime")
        #expect(unknown == nil)
        let cached = await service.catalog()
        #expect(cached == .empty)
    }

    // MARK: - SKTestSession-backed catalog + rawProduct round trip

    @Test func catalogReturnsCachedAfterLoad() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            _ = try await service.load()
            let first = await service.catalog()
            let second = await service.catalog()
            #expect(first == second)
            #expect(first.monthly?.id == StoreKitProductService.monthlyProductId)
        }
    }

    @Test func rawProductReturnsProductForKnownId() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            _ = try await service.load()
            let monthly = await service.rawProduct(for: StoreKitProductService.monthlyProductId)
            let annual  = await service.rawProduct(for: StoreKitProductService.annualProductId)
            #expect(monthly != nil)
            #expect(annual != nil)
            #expect(monthly?.id == StoreKitProductService.monthlyProductId)
        }
    }

    @Test func rawProductReturnsNilForUnknownId() async throws {
        try await withSKTestDaemon {
            let service = StoreKitProductService()
            _ = try await service.load()
            let unknown = await service.rawProduct(for: "org.fidexa.rishi.pro.lifetime")
            #expect(unknown == nil)
        }
    }

    // MARK: - Cache survives failure (test-only seam, no daemon required)

    @Test func loadFailureDoesNotClobberCache() async throws {
        let service = StoreKitProductService()
        // Seed the cache via the injected loader so this test is
        // daemon-independent. The shape mirrors what `Product.products(for:)`
        // would return in production — synthetic-empty isn't an option since
        // empty triggers `.noProductsReturned`. Instead: drive a live load
        // when the daemon is available, OR skip the seed step when not (and
        // assert the unchanged-empty contract).
        if await probeStoreKitTestDaemon() {
            let successful = try await service.load()
            #expect(successful.hasAny == true)
            await #expect(throws: StoreKitProductLoadError.self) {
                _ = try await service.loadForTesting { _ in
                    throw StoreKitProductLoadError.noProductsReturned
                }
            }
            let afterFailure = await service.catalog()
            #expect(afterFailure == successful,
                    "cache was clobbered after failed reload")
        } else {
            // Without the daemon: empty cache → still empty after failure.
            await #expect(throws: StoreKitProductLoadError.self) {
                _ = try await service.loadForTesting { _ in
                    throw StoreKitProductLoadError.noProductsReturned
                }
            }
            let afterFailure = await service.catalog()
            #expect(afterFailure == .empty)
        }
    }

    // MARK: - Sendable conformance (no daemon required)

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

    // MARK: - Helpers

    /// Run `body` only when the StoreKit Test daemon is available; otherwise
    /// record a `withKnownIssue` so the test reports as a soft-skip rather
    /// than a failure.
    private func withSKTestDaemon(_ body: () async throws -> Void) async throws {
        if await probeStoreKitTestDaemon() {
            try await body()
        } else {
            withKnownIssue("SKTestSession daemon unavailable on this host (typically `swift test` on macOS — products fail with ASDErrorDomain 650). Run via xcodebuild on an iOS simulator destination to exercise.") {
                Issue.record("skipped — no StoreKit Test daemon")
            }
        }
    }
}
