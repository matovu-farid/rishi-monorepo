import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiTesting
@testable import RishiReader

@Suite("EPUBReaderViewModel", .serialized)
struct EPUBReaderViewModelTests {

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
    }

    @Test("load() opens publication and sets title")
    func loadOpensPublicationAndSetsTitle() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = EPUBReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()
        #expect(vm.publication != nil)
        #expect(!vm.title.isEmpty)
    }

    @Test("didChangeLocation debounces position writes")
    func didChangeLocationDebounces() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = EPUBReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.1
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let baseHref = try #require(RelativeURL(path: firstLink.href))
        let mediaType = firstLink.mediaType ?? .xhtml
        func makeLocator(progression: Double) -> Locator {
            Locator(
                href: baseHref,
                mediaType: mediaType,
                locations: Locator.Locations(progression: progression, totalProgression: progression)
            )
        }

        // Fire 5 rapid updates; only the last (~0.5) should be persisted.
        for p in stride(from: 0.1, through: 0.5, by: 0.1) {
            vm.didChangeLocation(makeLocator(progression: p))
        }

        // Wait > debounce window
        try await Task.sleep(for: .milliseconds(300))

        let last = try await store.position(for: book.id)
        let storedWrapper = try #require(last.flatMap { try? EPUBPositionLocator.decode(jsonString: $0.locator) })
        let inner = try #require(storedWrapper.toReadiumLocator())
        let prog = inner.locations.totalProgression ?? 0
        // The LAST progression (≈ 0.5) should win — debounce coalesces.
        #expect(prog >= 0.4)
    }

    @Test("flush() persists immediately, bypassing the debounce")
    func flushPersistsImmediately() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = EPUBReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0   // long debounce — flush must beat it
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.25, totalProgression: 0.25)
        )
        vm.didChangeLocation(locator)
        await vm.flush()

        let last = try await store.position(for: book.id)
        #expect(last != nil)
    }

    @Test("load() restores last locator from store")
    func loadRestoresLastLocator() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()

        // Hand-craft a seed locator JSON we know is decodable
        let seedHref = try #require(RelativeURL(path: "chapter1.xhtml"))
        let seed = Locator(
            href: seedHref,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.42, totalProgression: 0.13)
        )
        let wrapped = EPUBPositionLocator(locator: seed)
        let encoded = try wrapped.encodedJSONString()
        let position = Position(
            bookId: book.id,
            locator: encoded,
            percentComplete: 0.13,
            updatedAt: Date()
        )
        try await store.upsert(position)

        let vm = EPUBReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        let restored = try #require(vm.latestLocator)
        let restoredHref = String(describing: restored.href)
        #expect(restoredHref.contains("chapter1.xhtml"))
    }
}
