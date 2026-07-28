@testable import rishi
import StoreKit
import Testing

@MainActor
@Suite("Active Store catalog")
struct StoreTests {

    @Test("a complete current-platform catalog is accepted")
    func completeCatalogIsAccepted() {
        let requested = ["reader.monthly", "voice.monthly"]

        #expect(Store.isCompleteCatalog(returnedIDs: requested, requestedIDs: requested))
    }

    @Test("empty catalog is distinguished from partial catalog")
    func emptyAndPartialCatalogsHaveDistinctErrors() {
        let requested = ["reader.monthly", "voice.monthly"]

        #expect(Store.catalogError(returnedIDs: [], requestedIDs: requested) == .emptyProductCatalog)
        #expect(Store.catalogError(returnedIDs: ["reader.monthly"], requestedIDs: requested) == .incompleteProductCatalog)
        #expect(Store.catalogError(returnedIDs: ["reader.monthly", "legacy.pro"], requestedIDs: requested) == .incompleteProductCatalog)
    }

    @Test("product requests are limited to the current platform catalog")
    func productRequestsExcludeLegacyAndOtherPlatformIDs() {
        #expect(fetchProductIDs() == RishiProductID.currentPlatformProductIDs)
        #expect(!fetchProductIDs().contains(RishiProductID.proMonthly))
        #expect(!fetchProductIDs().contains(RishiProductID.proAnnual))
        #expect(fetchProductIDs().allSatisfy { RishiProductID.readerAndVoice.contains($0) })
    }

    @Test("a failed retry clears the stale catalog and publishes failure")
    func failedRetryClearsStaleCatalog() async {
        let store = Store(productLoader: { _ in
            throw StoreError.productRequestFailed
        })

        await store.loadProducts()

        #expect(store.products.isEmpty)
        #expect(store.loadState == .failed)
        #expect(store.error == .productRequestFailed)
    }
}
