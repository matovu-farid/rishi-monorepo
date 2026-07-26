@testable import rishi
import Testing
import Foundation
import PDFKit
import CoreGraphics




/// Tests for the highlight surface on `PDFReaderViewModel` (plan 05-06 Task 3).
///
/// `@Suite(.serialized)` per project convention — tests mutate shared fixture
/// files in the temp dir and walk through the InMemoryHighlightStore (an
/// actor). Serial execution keeps the per-test PDF setup deterministic.
@Suite("PDFReaderViewModel + Highlights", .serialized)
struct PDFReaderViewModelHighlightsTests {

    // MARK: - Helpers

    private func makeFixture() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: false)
        return url
    }

    private func makeVM(url: URL) -> PDFReaderViewModel {
        let book = Book(userId: UUID(), title: "Hl", formatType: .pdf, fileURL: "x")
        return PDFReaderViewModel(
            book: book, userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 0.05
        )
    }

    // MARK: - Tests

    @Test("createHighlight persists a row with PDFHighlightLocator JSON in locatorStart")
    func createPersistsLocator() async throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = makeVM(url: url)
        await vm.load()
        let store = InMemoryHighlightStore()

        let locator = PDFHighlightLocator(
            page: 1,
            rects: [CGRect(x: 10, y: 20, width: 100, height: 14)],
            text: "selected"
        )
        let hl = try #require(await vm.createHighlight(color: .yellow, locator: locator, store: store))
        #expect(hl.color == .yellow)
        #expect(hl.text == "selected")

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.count == 1)
        let decoded = try PDFHighlightLocator.decode(jsonString: stored[0].locatorStart)
        #expect(decoded.page == 1)
        #expect(decoded.text == "selected")
        // PDF rows store the same locator in both ends (point-selection
        // contract for PDF — EPUB will use distinct start/end CFIs in
        // Phase 6).
        #expect(stored[0].locatorEnd == stored[0].locatorStart)
    }

    @Test("updateNote round-trips through the store")
    func updateNoteRoundTrips() async throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = makeVM(url: url)
        await vm.load()
        let store = InMemoryHighlightStore()

        let locator = PDFHighlightLocator(page: 0, rects: [.zero], text: "x")
        let hl = try #require(await vm.createHighlight(color: .pink, locator: locator, store: store))
        await vm.updateNote(on: hl, note: "Great paragraph", store: store)

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.first?.note == "Great paragraph")
    }

    @Test("deleteHighlight removes the row from the store and the cache")
    func deleteRemoves() async throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = makeVM(url: url)
        await vm.load()
        let store = InMemoryHighlightStore()

        let locator = PDFHighlightLocator(page: 0, rects: [.zero], text: "x")
        let hl = try #require(await vm.createHighlight(color: .green, locator: locator, store: store))
        await vm.deleteHighlight(hl, store: store)

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.isEmpty)
        #expect(vm.highlightsForCurrentPage.isEmpty)
    }

    @Test("loadHighlights seeds cache; highlightsForCurrentPage filters by page index")
    func loadHighlightsSeedsCacheAndFilters() async throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = makeVM(url: url)
        await vm.load()
        let store = InMemoryHighlightStore()

        let p0Json = try PDFHighlightLocator(page: 0, rects: [.zero], text: "p0").encodedJSONString()
        let p2Json = try PDFHighlightLocator(page: 2, rects: [.zero], text: "p2").encodedJSONString()
        try await store.upsert(Highlight(
            bookId: vm.book.id,
            locatorStart: p0Json, locatorEnd: p0Json,
            color: .yellow, text: "p0",
            createdAt: Date()
        ))
        try await store.upsert(Highlight(
            bookId: vm.book.id,
            locatorStart: p2Json, locatorEnd: p2Json,
            color: .blue, text: "p2",
            createdAt: Date()
        ))

        await vm.loadHighlights(from: store)
        // VM defaults to page 0
        #expect(vm.highlightsForCurrentPage.count == 1)
        #expect(vm.highlightsForCurrentPage.first?.color == .yellow)

        vm.seek(toPage: 2)
        #expect(vm.highlightsForCurrentPage.count == 1)
        #expect(vm.highlightsForCurrentPage.first?.color == .blue)
    }
}
