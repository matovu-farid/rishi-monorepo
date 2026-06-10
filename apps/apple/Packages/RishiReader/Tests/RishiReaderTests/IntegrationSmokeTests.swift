import Testing
import Foundation
import PDFKit
import RishiCore
import RishiTesting
@testable import RishiReader

@Suite("Phase 5 integration smoke", .serialized)
struct IntegrationSmokeTests {

    @Test("Bundled sample.pdf exists in package resources")
    func bundledSampleExists() throws {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        #expect(data.count < 200_000)
    }

    @Test("Bundled sample.pdf has 3 pages")
    func bundledSampleHasThreePages() throws {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 3)
    }

    @Test("Bundled sample.pdf has TOC with 3 entries")
    func bundledSampleHasTOC() throws {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let doc = try #require(PDFDocument(url: url))
        let nodes = PDFOutlineExtractor.extract(from: doc)
        #expect(nodes.count == 3)
    }

    @Test("VM round-trip: open sample, seek, flush, re-open, position restored")
    func roundTripPositionRestore() async throws {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let store = InMemoryPositionStore()
        let userId = UUID()
        let book = Book(userId: userId, title: "Sample", formatType: .pdf, fileURL: "x")

        let vm1 = PDFReaderViewModel(
            book: book, userId: userId, documentURL: url,
            positionStore: store, debounceSeconds: 0.05
        )
        await vm1.load()
        vm1.seek(toPage: 2)
        await vm1.flush()

        let vm2 = PDFReaderViewModel(
            book: book, userId: userId, documentURL: url,
            positionStore: store, debounceSeconds: 0.05
        )
        await vm2.load()
        #expect(vm2.pageIndex == 2)
    }

    @Test("Theme round-trip: set theme, reopen store, value restored")
    func themeRoundTrip() async {
        let suite = "IntegrationSmoke-theme-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let bookId = BookID()

        let writer = UserDefaultsReaderSettingsStore(defaults: defaults)
        await writer.setTheme(.dark, for: bookId)

        let reader = UserDefaultsReaderSettingsStore(defaults: defaults)
        #expect(await reader.theme(for: bookId) == .dark)
    }
}
