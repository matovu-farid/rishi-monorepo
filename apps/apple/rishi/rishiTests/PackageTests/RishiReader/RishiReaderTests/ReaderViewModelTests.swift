@testable import rishi
import Testing
import Foundation
import PDFKit
import ReadiumShared




@Suite("ReaderViewModel", .serialized)
struct ReaderViewModelTests {

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
    }

    @Test("load() opens publication and sets title")
    func loadOpensPublicationAndSetsTitle() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
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
        let vm = ReaderViewModel(
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
        let storedWrapper = try #require(last.flatMap { try? ReaderPositionLocator.decode(jsonString: $0.locator) })
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
        let vm = ReaderViewModel(
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

    @Test("didChangeLocation(isProgrammatic: false) fires onUserNavigation once with the locator")
    func userNavigationFiresOnUserNavigation() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.33, totalProgression: 0.33)
        )

        let received = LockedBox<[Locator]>([])
        vm.onUserNavigation = { loc in received.mutate { $0.append(loc) } }

        vm.didChangeLocation(locator, isProgrammatic: false)

        let captured = received.value
        #expect(captured.count == 1)
        let got = try #require(captured.first)
        #expect(String(describing: got.href) == String(describing: locator.href))
        #expect(got.locations.progression == locator.locations.progression)
    }

    @Test("didChangeLocation(isProgrammatic: true) does NOT fire onUserNavigation")
    func programmaticNavigationDoesNotFireOnUserNavigation() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.44, totalProgression: 0.44)
        )

        let received = LockedBox<[Locator]>([])
        vm.onUserNavigation = { loc in received.mutate { $0.append(loc) } }

        vm.didChangeLocation(locator, isProgrammatic: true)

        #expect(received.value.isEmpty)
    }

    @Test("didChangeLocation default fires the TTS page prefetch callback")
    func userNavigationFiresOnUserNavigationForTTSPagePrefetch() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.61, totalProgression: 0.61)
        )

        let received = LockedBox<[Locator]>([])
        vm.onUserNavigationForTTSPagePrefetch = { loc in
            received.mutate { $0.append(loc) }
        }

        vm.didChangeLocation(locator)

        let captured = received.value
        #expect(captured.count == 1)
        let got = try #require(captured.first)
        #expect(String(describing: got.href) == String(describing: locator.href))
        #expect(got.locations.progression == locator.locations.progression)
    }

    @Test("didChangeLocation programmatic does NOT fire the TTS page prefetch callback")
    func programmaticNavigationDoesNotFireOnUserNavigationForTTSPagePrefetch() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.72, totalProgression: 0.72)
        )

        let received = LockedBox<[Locator]>([])
        vm.onUserNavigationForTTSPagePrefetch = { loc in
            received.mutate { $0.append(loc) }
        }

        vm.didChangeLocation(locator, isProgrammatic: true)

        #expect(received.value.isEmpty)
    }

    @Test("live visible locator takes precedence over the last location callback for read aloud")
    @MainActor
    func currentVisibleLocatorForReadAloudUsesLiveProvider() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let oldLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.1, totalProgression: 0.1)
        )
        let liveLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.8, totalProgression: 0.8)
        )

        vm.didChangeLocation(oldLocator)
        vm.currentVisibleLocatorProvider = { liveLocator }

        let resolved = await vm.currentVisibleLocatorForReadAloud()

        #expect(resolved?.locations.progression == liveLocator.locations.progression)
    }

    @Test("firstParagraphForPageEntryPrefetch extracts the supplied page paragraph")
    func firstParagraphForPageEntryPrefetchUsesSuppliedLocator() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        var extracted: String?
        var expected: String?
        for link in publication.readingOrder {
            let href = try #require(RelativeURL(path: link.href))
            let locator = Locator(
                href: href,
                mediaType: link.mediaType ?? .xhtml,
                locations: Locator.Locations(progression: 0, totalProgression: 0)
            )
            vm.didChangeLocation(locator)

            if let paragraph = await vm.firstParagraphForPageEntryPrefetch(at: locator) {
                extracted = paragraph
                expected = await vm.paragraphsForReadAloud().first
                break
            }
        }

        #expect(extracted != nil)
        #expect(extracted == expected)
    }

    @Test("firstParagraphForPageEntryPrefetch extracts the first PDF sentence")
    func firstParagraphForPageEntryPrefetchUsesFirstPDFSentence() async throws {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "sample", withExtension: "pdf"))
        let store = InMemoryPositionStore()
        let book = Book(
            userId: UUID(),
            title: "Sample",
            formatType: .pdf,
            fileURL: "Books/x/sample.pdf"
        )
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let href = try #require(RelativeURL(path: "publication.pdf"))
        let locator = Locator(
            href: href,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=1"])
        )
        let extracted = await vm.firstParagraphForPageEntryPrefetch(at: locator)
        let passages = await vm.paragraphsForUserNavigationIntent(at: locator)

        #expect(extracted != nil)
        #expect(passages.count > 1)
        #expect(extracted == passages.first)
    }

    @Test("PDF user navigation returns sentence-level passages")
    func pdfUserNavigationUsesSentencePassages() async throws {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "sample", withExtension: "pdf"))
        let vm = ReaderViewModel(
            book: Book(
                userId: UUID(),
                title: "Sample",
                formatType: .pdf,
                fileURL: "Books/x/sample.pdf"
            ),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 5.0
        )
        await vm.load()

        let locator = Locator(
            href: try #require(RelativeURL(path: "publication.pdf")),
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=1"])
        )
        let passages = await vm.paragraphsForUserNavigationIntent(at: locator)

        #expect(passages.count > 1)
        #expect(passages.allSatisfy { $0.contains(where: { $0.isLetter || $0.isNumber }) })
    }

    @Test("PDF page-entry and navigation helpers safely fall back when content is unavailable")
    func pdfHelpersReturnSafeFallbackForUnavailableContent() async throws {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "sample", withExtension: "pdf"))
        let vm = ReaderViewModel(
            book: Book(
                userId: UUID(),
                title: "Sample",
                formatType: .pdf,
                fileURL: "Books/x/sample.pdf"
            ),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 5.0
        )
        await vm.load()

        let unavailableLocator = Locator(
            href: try #require(RelativeURL(path: "missing.pdf")),
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=1"])
        )

        #expect(await vm.firstParagraphForPageEntryPrefetch(at: unavailableLocator) == nil)
        #expect(await vm.paragraphsForUserNavigationIntent(at: unavailableLocator).isEmpty)
    }

    @Test("didChangeLocation default (no flag) fires onUserNavigation AND writes position")
    func defaultCallBehavesAsUserAndPersists() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.1
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.55, totalProgression: 0.55)
        )

        let received = LockedBox<[Locator]>([])
        vm.onUserNavigation = { loc in received.mutate { $0.append(loc) } }

        vm.didChangeLocation(locator)

        #expect(received.value.count == 1)

        // Position-write behavior unchanged: the debounced write still lands.
        try await Task.sleep(for: .milliseconds(300))
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

        let vm = ReaderViewModel(
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

/// Minimal thread-safe box so test closures can capture mutable state
/// without tripping Swift 6 concurrency diagnostics. The VM is
/// `@unchecked Sendable` and the closure is non-isolated, so the
/// captured storage must be Sendable.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&_value)
    }
}
