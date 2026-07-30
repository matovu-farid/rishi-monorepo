@testable import rishi
import Foundation
import PDFKit
import Testing

@Suite("Chapter source", .serialized)
struct ChapterSourceTests {

    @Test("EPUB chapters preserve TOC order, stable IDs, locators, and full resource text")
    func epubSourceReturnsOrderedRecords() async throws {
        let fixture = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let publication = try await PublicationLoader().open(fileURL: fixture)

        let snapshot = await EPUBChapterSource.snapshot(from: publication)
        let result = await EPUBChapterSource(snapshot: snapshot).chapters()
        let expected: [(href: String, name: String)] = [
            ("6517791129234588483_11-h-0.htm.html#pgepubid00000", "Alice’s Adventures in Wonderland"),
            ("6517791129234588483_11-h-0.htm.html#pgepubid00001", "THE MILLENNIUM FULCRUM EDITION 3.0"),
            ("6517791129234588483_11-h-0.htm.html#pgepubid00002", "Contents"),
            ("6517791129234588483_11-h-1.htm.html#pgepubid00003", "CHAPTER I. Down the Rabbit-Hole"),
            ("6517791129234588483_11-h-2.htm.html#pgepubid00004", "CHAPTER II. The Pool of Tears"),
            ("6517791129234588483_11-h-3.htm.html#pgepubid00005", "CHAPTER III. A Caucus-Race and a Long Tale"),
            ("6517791129234588483_11-h-4.htm.html#pgepubid00006", "CHAPTER IV. The Rabbit Sends in a Little Bill"),
            ("6517791129234588483_11-h-5.htm.html#pgepubid00007", "CHAPTER V. Advice from a Caterpillar"),
            ("6517791129234588483_11-h-6.htm.html#pgepubid00008", "CHAPTER VI. Pig and Pepper"),
            ("6517791129234588483_11-h-7.htm.html#pgepubid00009", "CHAPTER VII. A Mad Tea-Party"),
            ("6517791129234588483_11-h-8.htm.html#pgepubid00010", "CHAPTER VIII. The Queen’s Croquet-Ground"),
            ("6517791129234588483_11-h-9.htm.html#pgepubid00011", "CHAPTER IX. The Mock Turtle’s Story"),
            ("6517791129234588483_11-h-10.htm.html#pgepubid00012", "CHAPTER X. The Lobster Quadrille"),
            ("6517791129234588483_11-h-11.htm.html#pgepubid00013", "CHAPTER XI. Who Stole the Tarts?"),
            ("6517791129234588483_11-h-12.htm.html#pgepubid00014", "CHAPTER XII. Alice’s Evidence"),
            ("6517791129234588483_11-h-12.htm.html#pg-footer-heading", "THE FULL PROJECT GUTENBERG™ LICENSE"),
        ]

        #expect(result.isAvailable)
        #expect(result.availability == .available)
        let actualHrefs = result.records.compactMap { record -> String? in
            guard case .epub(let href) = record.locator else { return nil }
            return href
        }
        #expect(actualHrefs == expected.map(\.href))
        #expect(result.records.map(\.name) == expected.map(\.name))
        #expect(result.records.map(\.id) == expected.map { "epub:\($0.href)" })
        #expect(Set(result.records.map(\.id)).count == result.records.count)
        #expect(result.records[3].text.localizedCaseInsensitiveContains("Alice was beginning to get very tired"))
        #expect(result.records.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test("PDF chapters use outline destinations and end before the next chapter")
    func pdfSourceReturnsPageRangesAndText() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("chapter-source-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: true)
        let document = try #require(PDFDocument(url: url))

        let snapshot = await PDFChapterSource.snapshot(from: document)
        let result = await PDFChapterSource(snapshot: snapshot).chapters()

        guard case .partialFailure(let diagnostics) = result.availability else {
            Issue.record("Expected a partial result because the image-only fixture has no selectable text")
            return
        }
        #expect(!diagnostics.isEmpty)
        #expect(result.records.map(\.name) == ["Part 1", "Chapter 1", "Chapter 2"])
        #expect(result.records.map(\.id) == ["pdf:0:part-1", "pdf:1:chapter-1", "pdf:2:chapter-2"])
        let actualRanges = result.records.compactMap { record -> String? in
            guard case .pdf(let range) = record.locator else { return nil }
            return "\(range.startPage)-\(range.endPage)"
        }
        #expect(actualRanges == ["0-0", "1-1", "2-2"])
        #expect(Set(result.records.map(\.id)).count == result.records.count)
    }

    @Test("PDF source is explicitly unavailable when no usable outline exists")
    func outlineLessPDFDoesNotInventChapters() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("chapter-source-empty-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 2, withOutline: false)
        let document = try #require(PDFDocument(url: url))

        let snapshot = await PDFChapterSource.snapshot(from: document)
        let result = await PDFChapterSource(snapshot: snapshot).chapters()

        #expect(!result.isAvailable)
        guard case .unavailable(let diagnostics) = result.availability else {
            Issue.record("Expected an unavailable diagnostic")
            return
        }
        #expect(!diagnostics.isEmpty)
        #expect(result.records.isEmpty)
    }

    @Test("duplicate PDF outline starts still produce unique chapter IDs")
    func duplicatePDFOutlineStartsReceiveUniqueIDs() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("chapter-source-duplicate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: true)
        let document = try #require(PDFDocument(url: url))
        let root = try #require(document.outlineRoot)
        let duplicate = PDFOutline()
        duplicate.label = "Chapter 2"
        duplicate.destination = PDFDestination(page: try #require(document.page(at: 2)), at: .zero)
        root.insertChild(duplicate, at: root.numberOfChildren)

        let snapshot = await PDFChapterSource.snapshot(from: document)
        let result = await PDFChapterSource(snapshot: snapshot).chapters()
        let ids = result.records.map(\.id)

        #expect(ids.contains("pdf:2:chapter-2"))
        #expect(ids.contains("pdf:2:chapter-2|duplicate-2"))
        #expect(Set(ids).count == ids.count)
    }

    @Test("duplicate EPUB and PDF chapter bases receive deterministic unique IDs")
    func duplicateChapterBasesReceiveUniqueIDs() {
        let epubIDs = (0..<2).map {
            ChapterSourceIDAllocator.id(base: "epub:chapter.xhtml", occurrence: $0)
        }
        let pdfIDs = (0..<2).map {
            ChapterSourceIDAllocator.id(base: "pdf:4:chapter", occurrence: $0)
        }

        #expect(epubIDs == ["epub:chapter.xhtml", "epub:chapter.xhtml|duplicate-2"])
        #expect(pdfIDs == ["pdf:4:chapter", "pdf:4:chapter|duplicate-2"])
        #expect(Set(epubIDs).count == epubIDs.count)
        #expect(Set(pdfIDs).count == pdfIDs.count)
    }

    @Test("runtime chapter sources execute from value-only snapshots")
    func runtimeSourcesDoNotNeedFrameworkObjects() async {
        let record = ChapterSourceRecord(
            id: "epub:chapter.xhtml",
            name: "Chapter",
            locator: .epub(href: "chapter.xhtml"),
            text: "Known text"
        )
        let snapshot = ChapterSourceResult(availability: .available, records: [record])

        #expect(await EPUBChapterSource(snapshot: snapshot).chapters() == snapshot)
        #expect(await PDFChapterSource(snapshot: snapshot).chapters() == snapshot)
    }
}
