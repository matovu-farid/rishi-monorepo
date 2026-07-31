@testable import rishi
import Testing
import Foundation
import PDFKit




@Suite("PDFReaderViewModel", .serialized)
struct PDFReaderViewModelTests {

    private func makeFixture(pageCount: Int, withOutline: Bool = true) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("vm-fix-\(UUID().uuidString).pdf")
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: pageCount, withOutline: withOutline)
        return url
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Fixture", formatType: .pdf, fileURL: "Books/x/fix.pdf")
    }

    private func makeParagraphFixture() throws -> (url: URL, pageIndex: Int, paragraphs: [String]) {
        let url = try #require(
            PackageTestResourceBundle.bundle.url(forResource: "how-to-prove-it", withExtension: "pdf")
        )
        let document = try #require(PDFDocument(url: url))

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let paragraphs = PDFReadAloudParagraphs.paragraphs(from: page)
            if paragraphs.count >= 2 {
                return (url, pageIndex, paragraphs)
            }
        }

        Issue.record("Fixture did not contain a page with at least two paragraphs")
        throw FixtureError.noParagraphPage
    }

    private enum FixtureError: Error {
        case noParagraphPage
    }

    @Test("PDFPositionEncoder round-trips")
    func encoderRoundTrips() {
        let enc = PDFPositionEncoder.encode(page: 42)
        #expect(enc == "pdf-v1:page:42")
        #expect(PDFPositionEncoder.decode(enc) == 42)
    }

    @Test("PDF v2 position round-trips paragraph identity")
    func v2PositionRoundTrips() throws {
        let locator = PDFPositionEncoder.encode(
            page: 3, paragraph: 2, text: "The current paragraph."
        )
        let decoded = try #require(PDFPositionEncoder.decodePosition(locator))

        #expect(decoded.pageIndex == 3)
        #expect(decoded.paragraphIndex == 2)
        #expect(decoded.paragraphHash == PDFPositionEncoder.paragraphHash("The current paragraph."))
        #expect(locator == "pdf-v2:page:3:paragraph:2:hash:\(decoded.paragraphHash ?? "")")
    }

    @Test("PDF v1 position remains page-only")
    func v1PositionRemainsCompatible() throws {
        let decoded = try #require(PDFPositionEncoder.decodePosition("pdf-v1:page:3"))

        #expect(decoded.pageIndex == 3)
        #expect(decoded.paragraphIndex == nil)
        #expect(decoded.paragraphHash == nil)
        #expect(PDFPositionEncoder.decode("pdf-v1:page:3") == 3)
    }

    @Test("PDFPositionEncoder rejects malformed v2 locators")
    func encoderRejectsMalformedV2() {
        #expect(PDFPositionEncoder.decodePosition("pdf-v2:page:3") == nil)
        #expect(PDFPositionEncoder.decodePosition("pdf-v2:page:3:paragraph:not-a-number:hash:0123456789abcdef") == nil)
        #expect(PDFPositionEncoder.decodePosition("pdf-v2:page:3:paragraph:2:hash:too-short") == nil)
        #expect(PDFPositionEncoder.decodePosition("pdf-v2:page:3:paragraph:2:hash:0123456789abcdeg") == nil)
        #expect(PDFPositionEncoder.decodePosition("pdf-v2:page:3:paragraph:2:hash:0123456789abcdef:extra") == nil)
    }

    @Test("paragraph hashing normalizes whitespace deterministically")
    func paragraphHashNormalizesWhitespace() {
        let expected = PDFPositionEncoder.paragraphHash("The current paragraph.")

        #expect(expected == "d4c887748be6ed03")
        #expect(PDFPositionEncoder.paragraphHash("  The   current\nparagraph.  ") == expected)
        #expect(PDFPositionEncoder.paragraphHash("The current paragraph!") != expected)
        #expect(expected.count == 16)
    }

    @Test("PDFPositionEncoder rejects malformed locator strings")
    func encoderRejectsMalformed() {
        #expect(PDFPositionEncoder.decode("epub-v1:cfi:/2[ch1]") == nil)
        #expect(PDFPositionEncoder.decode("pdf-v1:page:not-a-number") == nil)
        #expect(PDFPositionEncoder.decode("pdf-v1:page") == nil)
        #expect(PDFPositionEncoder.decode("") == nil)
    }

    @Test("load() restores last position from PositionStore")
    func loadRestoresLastPosition() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 5)
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed last position at page 3
        let seeded = Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(page: 3),
            percentComplete: 0.6,
            updatedAt: Date()
        )
        try await store.upsert(seeded)

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        #expect(vm.totalPages == 5)
        #expect(vm.pageIndex == 3)
        #expect(vm.outline.count == 1)  // Part 1 root from fixture
    }

    @Test("load restores a matching PDF read-aloud paragraph")
    func loadRestoresReadAloudParagraph() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let expectedParagraph = fixture.paragraphs[1]
        try await store.upsert(Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(
                page: fixture.pageIndex,
                paragraph: 1,
                text: expectedParagraph
            ),
            percentComplete: 0,
            updatedAt: Date()
        ))

        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        #expect(vm.pageIndex == fixture.pageIndex)
        #expect(vm.readAloudStartParagraphIndex == 1)
    }

    @Test("load keeps the page but resets the paragraph when its hash mismatches")
    func loadResetsReadAloudParagraphForHashMismatch() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        try await store.upsert(Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(
                page: fixture.pageIndex,
                paragraph: 1,
                text: "A paragraph that is no longer on the page."
            ),
            percentComplete: 0,
            updatedAt: Date()
        ))

        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        #expect(vm.pageIndex == fixture.pageIndex)
        #expect(vm.readAloudStartParagraphIndex == 0)
    }

    @Test("load keeps the page but resets an out-of-range paragraph")
    func loadResetsOutOfRangeReadAloudParagraph() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        try await store.upsert(Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(
                page: fixture.pageIndex,
                paragraph: fixture.paragraphs.count,
                text: "An out-of-range paragraph."
            ),
            percentComplete: 0,
            updatedAt: Date()
        ))

        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        #expect(vm.pageIndex == fixture.pageIndex)
        #expect(vm.readAloudStartParagraphIndex == 0)
    }

    @Test("load restores a v1 page and starts at paragraph zero")
    func loadRestoresV1PositionAtParagraphZero() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        try await store.upsert(Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(page: fixture.pageIndex),
            percentComplete: 0,
            updatedAt: Date()
        ))

        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        #expect(vm.pageIndex == fixture.pageIndex)
        #expect(vm.readAloudStartParagraphIndex == 0)
    }

    @Test("didChangeReadAloudPassage writes a v2 paragraph locator after debounce")
    func didChangeReadAloudPassageWritesV2AfterDebounce() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        vm.seek(toPage: fixture.pageIndex)
        vm.didChangeReadAloudPassage(to: 1, text: fixture.paragraphs[1])
        #expect(vm.readAloudStartParagraphIndex == 1)
        try await Task.sleep(for: .milliseconds(150))

        let stored = try #require(try await store.position(for: book.id))
        let decoded = try #require(PDFPositionEncoder.decodePosition(stored.locator))
        #expect(decoded.pageIndex == fixture.pageIndex)
        #expect(decoded.paragraphIndex == 1)
        #expect(decoded.paragraphHash == PDFPositionEncoder.paragraphHash(fixture.paragraphs[1]))
    }

    @Test("didChangeReadAloudPassage persists the canonical paragraph text")
    func didChangeReadAloudPassagePersistsCanonicalParagraphText() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        vm.seek(toPage: fixture.pageIndex)
        let canonicalText = fixture.paragraphs[1]
        vm.didChangeReadAloudPassage(to: 1, text: "deliberately different callback text")
        try await Task.sleep(for: .milliseconds(150))

        let stored = try #require(try await store.position(for: book.id))
        let decoded = try #require(PDFPositionEncoder.decodePosition(stored.locator))
        #expect(decoded.paragraphHash == PDFPositionEncoder.paragraphHash(canonicalText))
    }

    @Test("flush preserves a v2 paragraph locator")
    func flushPreservesV2ParagraphLocator() async throws {
        let fixture = try makeParagraphFixture()
        let store = InMemoryPositionStore()
        let book = makeBook()
        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: fixture.url,
            positionStore: store,
            debounceSeconds: 5.0
        )
        await vm.load()

        vm.seek(toPage: fixture.pageIndex)
        vm.didChangeReadAloudPassage(to: 1, text: fixture.paragraphs[1])
        await vm.flush()

        let stored = try #require(try await store.position(for: book.id))
        let decoded = try #require(PDFPositionEncoder.decodePosition(stored.locator))
        #expect(decoded.pageIndex == fixture.pageIndex)
        #expect(decoded.paragraphIndex == 1)
        #expect(decoded.paragraphHash == PDFPositionEncoder.paragraphHash(fixture.paragraphs[1]))
    }

    @Test("didChangePage debounces position writes (~1s window)")
    func didChangePageDebouncesWrites() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 0.1
        )
        await vm.load()

        // Rapid-fire 5 page changes within debounce window
        for i in 1...5 { vm.didChangePage(toIndex: i) }
        // Wait > debounce window
        try await Task.sleep(for: .milliseconds(250))

        let last = try await store.position(for: book.id)
        #expect(last != nil)
        let stored = try #require(last.flatMap { PDFPositionEncoder.decode($0.locator) })
        // The LAST page wins (5), not any intermediate one
        #expect(stored == 5)
    }

    @Test("seek(toPage:) updates pageIndex and persists after debounce")
    func seekUpdatesAndPersists() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        vm.seek(toPage: 2)
        #expect(vm.pageIndex == 2)
        try await Task.sleep(for: .milliseconds(150))
        let last = try await store.position(for: book.id)
        #expect(PDFPositionEncoder.decode(last?.locator ?? "") == 2)
    }

    @Test("flush() writes immediately on dismiss, beating long debounce")
    func flushWritesImmediately() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 5.0  // long debounce — flush must beat it
        )
        await vm.load()
        vm.didChangePage(toIndex: 2)
        await vm.flush()

        let last = try await store.position(for: book.id)
        #expect(PDFPositionEncoder.decode(last?.locator ?? "") == 2)
    }
}
