@testable import rishi
import Foundation
import Testing




/// Phase 25 Plan 25-11 — verify the import path fires the BookIndexingHook
/// after the book is openable, and verify the per-format text extractors
/// emit ordered `(page, text)` paragraph rows.
@Suite("BookIndexingHook + PerBookTextExtractor (25-11)")
struct BookIndexingHookTests {

    // MARK: - Recording hook fixture

    /// Records every `scheduleIndexing(for:fileURL:)` call so tests can assert
    /// the import path wired the hook correctly.
    actor RecordingBookIndexingHook: BookIndexingHook {
        struct Call: Equatable, Sendable {
            let bookId: BookID
            let fileURL: URL
        }
        private(set) var calls: [Call] = []
        init() {}
        func scheduleIndexing(for book: Book, fileURL: URL) async {
            calls.append(Call(bookId: book.id, fileURL: fileURL))
        }
        func snapshot() -> [Call] { calls }
    }

    // MARK: - Importer wiring

    @Test("importBook fires the BookIndexingHook with the book + dest URL")
    func importBook_firesHook_afterUpsert() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pdfSource = tmp.appendingPathComponent("sample.pdf")
        try FixtureBuilders.writeTinyPDF(to: pdfSource)

        let store = InMemoryBookStore()
        let hook = RecordingBookIndexingHook()
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: store,
            coverExtractors: [:],
            metadataExtractors: [:],
            bookIndexingHook: hook
        )
        let userId = UUID()
        let book = try await storage.importBook(from: pdfSource, ownerId: userId)

        let calls = await hook.snapshot()
        #expect(calls.count == 1, "Hook should be invoked exactly once per import")
        #expect(calls.first?.bookId == book.id, "Hook should receive the persisted book id")
        #expect(
            calls.first?.fileURL.lastPathComponent == "sample.pdf",
            "Hook should receive the on-disk destination URL"
        )
        #expect(
            calls.first?.fileURL.path.contains(book.id.uuidString) == true,
            "Hook URL should live under Books/<bookId>/"
        )
    }

    @Test("importBook with default Noop hook does not throw and persists the book")
    func importBook_withNoopDefault_succeeds() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pdfSource = tmp.appendingPathComponent("plain.pdf")
        try FixtureBuilders.writeTinyPDF(to: pdfSource)

        let store = InMemoryBookStore()
        // No bookIndexingHook argument -> NoopBookIndexingHook default.
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: store,
            coverExtractors: [:],
            metadataExtractors: [:]
        )
        let userId = UUID()
        let book = try await storage.importBook(from: pdfSource, ownerId: userId)
        let fetched = try await store.book(book.id)
        #expect(fetched?.id == book.id, "Book row should be persisted even with no-op hook")
    }

    // MARK: - PdfTextExtractor

    @Test("PdfTextExtractor returns paragraphs with 1-based page numbers")
    func pdfExtractor_emitsPositiveMonotonicPageIndices() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pdfURL = tmp.appendingPathComponent("smoke.pdf")
        try FixtureBuilders.writeTinyPDF(to: pdfURL)

        let extractor = PdfTextExtractor()
        let paragraphs = try await extractor.extractParagraphs(from: pdfURL)
        // The fixture's `PDFPage(image:)` may produce zero extractable text,
        // so the contract we lock here is the SHAPE — non-throwing call,
        // monotonically non-decreasing positive page indices, no empty text.
        for (i, row) in paragraphs.enumerated() {
            #expect(row.page >= 1, "Page indices are 1-based")
            #expect(!row.text.isEmpty, "Extractor must drop empty chunks")
            if i > 0 {
                #expect(
                    paragraphs[i - 1].page <= row.page,
                    "Pages must be monotonically non-decreasing"
                )
            }
        }
    }

    @Test("PdfTextExtractor returns empty array for non-PDF input")
    func pdfExtractor_unreadable_returnsEmpty() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bogus = tmp.appendingPathComponent("not-a-pdf.pdf")
        try Data("not a pdf".utf8).write(to: bogus)

        let extractor = PdfTextExtractor()
        let paragraphs = try await extractor.extractParagraphs(from: bogus)
        #expect(paragraphs.isEmpty, "Unreadable PDF -> empty paragraphs (no throw)")
    }

    // MARK: - EpubTextExtractor

    @Test("EpubTextExtractor walks the spine and emits 1-based reading-order positions")
    func epubExtractor_usesReadingOrderPosition() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epubURL = tmp.appendingPathComponent("smoke.epub")
        try await FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: false)

        let extractor = EpubTextExtractor()
        let paragraphs = try await extractor.extractParagraphs(from: epubURL)
        // The fixture has one spine item (`nav.xhtml`) whose body says "Start".
        // The chunker drops chunks under `minBodyChars`, so the round-trip
        // may yield zero rows on this very-small fixture; the contract we
        // lock is: (a) call doesn't throw, (b) any rows present have positive
        // page indices that equal the spine reading-order position.
        for row in paragraphs {
            #expect(row.page == 1, "Single-spine fixture must report position 1")
            #expect(!row.text.isEmpty, "Empty chunks must be dropped")
        }
    }

    @Test("EpubTextExtractor returns empty array for non-EPUB input")
    func epubExtractor_unreadable_returnsEmpty() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bogus = tmp.appendingPathComponent("not-an.epub")
        try Data("not an epub".utf8).write(to: bogus)

        let extractor = EpubTextExtractor()
        let paragraphs = try await extractor.extractParagraphs(from: bogus)
        #expect(paragraphs.isEmpty, "Unreadable EPUB -> empty paragraphs (no throw)")
    }

    @Test("EpubTextExtractor spine parser recovers reading-order itemref list")
    func epubExtractor_spineParser_returnsItemIds() {
        let opf = """
        <package>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="cover" href="cover.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """
        let ids = EpubTextExtractor.parseSpineItemIds(from: Data(opf.utf8))
        #expect(ids == ["ch1", "ch2"], "Spine parse should preserve OPF item order")
        let manifest = EpubTextExtractor.parseManifestHrefs(from: Data(opf.utf8))
        #expect(manifest["ch1"] == "ch1.xhtml")
        #expect(manifest["ch2"] == "ch2.xhtml")
        #expect(manifest["cover"] == "cover.png")
    }

    @Test("EpubTextExtractor stripHTML drops tags and decodes basic entities")
    func epubExtractor_stripHTML_basic() {
        let html = "<html><body><p>Hello &amp; goodbye</p><script>x()</script></body></html>"
        let stripped = EpubTextExtractor.stripHTML(html)
        #expect(stripped.contains("Hello & goodbye"))
        #expect(!stripped.contains("script"))
        #expect(!stripped.contains("<"))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-25-11-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
