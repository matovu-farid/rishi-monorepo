@testable import rishi
import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ReadiumShared




@Suite("ReaderViewModel", .serialized)
@MainActor
struct ReaderViewModelTests {

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    private func samplePDFURL() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("reader-navigation-\(UUID().uuidString).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        // Indented first lines create paragraph boundaries. Most lines remain
        // flush left so the paragraph grouper's modal margin stays at x=72.
        for (index, text) in [
            "The first paragraph describes a quiet garden.",
            "Flowers bloom beside the garden path.",
            "The second paragraph describes a sunny meadow.",
            "Tall grasses sway beneath the clear sky.",
            "The third paragraph describes a flowing river.",
            "Water runs past the stones along its banks."
        ].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]
            ))
            let isIndentedFirstLine = index == 2 || index == 4
            context.textPosition = CGPoint(x: isIndentedFirstLine ? 90 : 72, y: 720 - CGFloat(index) * 18)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        try #require(text.contains("The first paragraph"))
        try #require(text.contains("The third paragraph"))
        try #require(PDFReadAloudParagraphs.extract(from: page).count == 3)
        return url
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

    @Test("explicit page-forward locations use their tagged callback instead of generic user navigation")
    func explicitPageForwardUsesTaggedCallback() async throws {
        let url = try aliceURL()
        let vm = ReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 5.0
        )
        await vm.load()
        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let locator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.5, totalProgression: 0.5)
        )
        let intentID = UUID()
        var genericNavigationCount = 0
        var prefetchCount = 0
        var explicitEvents: [(Locator, UUID)] = []
        vm.onUserNavigation = { _ in genericNavigationCount += 1 }
        vm.onUserNavigationForTTSPagePrefetch = { _ in prefetchCount += 1 }
        vm.onExplicitPageForwardNavigation = { location, id in explicitEvents.append((location, id)) }

        vm.didChangeLocation(locator, explicitForwardID: intentID)

        #expect(explicitEvents.count == 1)
        #expect(explicitEvents.first?.0.locations.progression == locator.locations.progression)
        #expect(explicitEvents.first?.1 == intentID)
        #expect(genericNavigationCount == 0)
        #expect(prefetchCount == 0)
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

    @Test("read-aloud location persists without firing user navigation")
    func readAloudLocationPersistsWithoutUserNavigation() async throws {
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
        let visibleLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.1, totalProgression: 0.1)
        )
        let narratedLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.7, totalProgression: 0.7)
        )
        let userNavigationCount = LockedBox(0)
        vm.onUserNavigation = { _ in userNavigationCount.mutate { $0 += 1 } }

        vm.didChangeLocation(visibleLocator)
        vm.didChangeReadAloudLocation(narratedLocator)
        await vm.flush()

        let stored = try #require(await store.position(for: book.id))
        let wrapper = try #require(try? ReaderPositionLocator.decode(jsonString: stored.locator))
        let restored = try #require(wrapper.toReadiumLocator())
        #expect(userNavigationCount.value == 1)
        #expect(restored.locations.progression == narratedLocator.locations.progression)
        #expect(restored.locations.totalProgression == narratedLocator.locations.totalProgression)
    }

    @Test("programmatic shared navigation updates visible locator without replacing narration resume")
    func programmaticSharedNavigationKeepsVisibleAndNarrationLocatorsSeparate() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let vm = ReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        let publication = try #require(vm.publication)
        let firstLink = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: firstLink.href))
        let mediaType = firstLink.mediaType ?? .xhtml
        let oldNarrationLocator = Locator(
            href: href,
            mediaType: mediaType,
            locations: Locator.Locations(progression: 0.25, totalProgression: 0.25)
        )
        let newVisibleLocator = Locator(
            href: href,
            mediaType: mediaType,
            locations: Locator.Locations(progression: 0.8, totalProgression: 0.8)
        )
        let userNavigationCount = LockedBox(0)
        vm.onUserNavigation = { _ in userNavigationCount.mutate { $0 += 1 } }

        vm.didChangeReadAloudLocation(oldNarrationLocator)
        vm.didChangeLocation(newVisibleLocator, isProgrammatic: true)

        let visible = try #require(vm.visibleNavigatorLocator)
        let narrationResume = try #require(vm.latestLocator)
        #expect(visible.locations.progression == newVisibleLocator.locations.progression)
        #expect(narrationResume.locations.progression == oldNarrationLocator.locations.progression)
        #expect(userNavigationCount.value == 0)
    }

    @Test("manual navigation remains authoritative after a read-aloud update")
    @MainActor
    func manualNavigationRemainsAuthoritativeAfterReadAloudUpdate() async throws {
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
        let narratedLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.2, totalProgression: 0.2)
        )
        let manualLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.9, totalProgression: 0.9)
        )

        vm.didChangeReadAloudLocation(narratedLocator)
        vm.didChangeLocation(manualLocator)
        vm.currentVisibleLocatorProvider = { narratedLocator }
        let start = try #require(await vm.readAloudStartLocator())
        await vm.flush()

        let stored = try #require(await store.position(for: book.id))
        let wrapper = try #require(try? ReaderPositionLocator.decode(jsonString: stored.locator))
        let restored = try #require(wrapper.toReadiumLocator())
        #expect(start.locations.progression == manualLocator.locations.progression)
        #expect(restored.locations.progression == manualLocator.locations.progression)
        #expect(restored.locations.totalProgression == manualLocator.locations.totalProgression)
    }

    @Test("saved read-aloud locator wins over the live visible locator")
    @MainActor
    func savedReadAloudLocatorWinsOverVisibleLocator() async throws {
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
        let savedLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.4, totalProgression: 0.4)
        )
        let visibleLocator = Locator(
            href: href,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.05, totalProgression: 0.05)
        )

        vm.didChangeReadAloudLocation(savedLocator)
        await vm.flush()

        let restoredVM = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await restoredVM.load()
        restoredVM.currentVisibleLocatorProvider = { visibleLocator }

        let start = try #require(await restoredVM.readAloudStartLocator())
        #expect(start.locations.progression == savedLocator.locations.progression)
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
        let url = try samplePDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
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
        let url = try samplePDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
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

    @Test("PDF voice context exposes the current page")
    func pdfVoiceContextExposesCurrentPage() async throws {
        let url = try samplePDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
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
        vm.didChangeLocation(locator, isInitialLocation: true)

        let context = vm.voiceContext()
        let liveContext = await vm.liveVoiceContext()

        #expect(context.currentPage == 1)
        #expect(liveContext.currentPage == 1)
        #expect(liveContext.pageText?.isEmpty == false)
    }

    @Test("PDF page-entry and navigation helpers safely fall back when content is unavailable")
    func pdfHelpersReturnSafeFallbackForUnavailableContent() async throws {
        let url = try samplePDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
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
/// without changing the existing callback-recording helpers during the
/// reader model's MainActor migration.
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
