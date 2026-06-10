import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiTesting
@testable import RishiReader

/// Tests for the highlight surface on ``EPUBReaderViewModel`` (plan 06-05
/// Task 2). Mirrors ``PDFReaderViewModelHighlightsTests`` — same
/// create/update/delete/load contract, EPUB-specific locator wire format.
///
/// `@Suite(.serialized)` per project convention — the external highlight
/// cache (per-instance, ObjectIdentifier-keyed) needs deterministic
/// ordering across tests because every VM mutation bumps an `@Observable`
/// trigger property.
@Suite("EPUBReaderViewModel + Highlights", .serialized)
struct EPUBReaderViewModelHighlightsTests {

    // MARK: - Helpers

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeVM() throws -> EPUBReaderViewModel {
        let url = try aliceURL()
        let book = Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
        return EPUBReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 0.05
        )
    }

    private func makeLocator(text: String) -> EPUBHighlightLocator {
        let inner = Locator(
            href: RelativeURL(path: "chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.25),
            text: Locator.Text(highlight: text)
        )
        return EPUBHighlightLocator(locator: inner)
    }

    // MARK: - Tests

    @Test("createHighlight persists row with EPUBHighlightLocator JSON in locatorStart")
    func createPersistsLocator() async throws {
        let vm = try makeVM()
        await vm.load()
        let store = InMemoryHighlightStore()
        let locator = makeLocator(text: "down the rabbit hole")
        let hl = try #require(await vm.createHighlight(color: .yellow, locator: locator, store: store))
        #expect(hl.color == .yellow)
        #expect(hl.text == "down the rabbit hole")

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.count == 1)
        let decoded = try EPUBHighlightLocator.decode(jsonString: stored[0].locatorStart)
        #expect(decoded.text == "down the rabbit hole")
        // EPUB writes the same wire payload to both start/end (point-selection
        // for v1; future range selections may diverge — schema bump epub-v2).
        #expect(stored[0].locatorEnd == stored[0].locatorStart)
    }

    @Test("updateNote round-trips through store")
    func updateNoteRoundTrips() async throws {
        let vm = try makeVM()
        await vm.load()
        let store = InMemoryHighlightStore()
        let locator = makeLocator(text: "x")
        let hl = try #require(await vm.createHighlight(color: .pink, locator: locator, store: store))

        await vm.updateNote(on: hl, note: "Curiouser and curiouser", store: store)

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.first?.note == "Curiouser and curiouser")
        // Cache reflects the update too.
        #expect(vm.loadedHighlights.first?.note == "Curiouser and curiouser")
    }

    @Test("deleteHighlight removes from store and cache")
    func deleteRemoves() async throws {
        let vm = try makeVM()
        await vm.load()
        let store = InMemoryHighlightStore()
        let locator = makeLocator(text: "x")
        let hl = try #require(await vm.createHighlight(color: .green, locator: locator, store: store))
        await vm.deleteHighlight(hl, store: store)

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.isEmpty)
        #expect(vm.loadedHighlights.isEmpty)
    }

    @Test("loadHighlights seeds cache from store")
    func loadHighlightsSeedsCache() async throws {
        let vm = try makeVM()
        await vm.load()
        let store = InMemoryHighlightStore()

        let locator = makeLocator(text: "Alice")
        let json = try locator.encodedJSONString()
        try await store.upsert(Highlight(
            bookId: vm.book.id,
            locatorStart: json,
            locatorEnd: json,
            color: .blue,
            text: "Alice",
            note: nil,
            createdAt: Date()
        ))

        await vm.loadHighlights(from: store)
        #expect(vm.loadedHighlights.count == 1)
        #expect(vm.loadedHighlights.first?.color == .blue)
    }

    @Test("createHighlight with note persists the note inline")
    func createHighlightWithNote() async throws {
        let vm = try makeVM()
        await vm.load()
        let store = InMemoryHighlightStore()
        let locator = makeLocator(text: "snippet")
        let hl = try #require(await vm.createHighlight(
            color: .yellow,
            locator: locator,
            note: "First impressions",
            store: store
        ))
        #expect(hl.note == "First impressions")

        let stored = try await store.highlights(for: vm.book.id)
        #expect(stored.first?.note == "First impressions")
    }
}
