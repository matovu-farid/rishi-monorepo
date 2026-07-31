@testable import rishi
import Testing
import Foundation
import PDFKit


@Suite("PDFOutlineExtractor", .serialized)
struct PDFOutlineExtractorTests {

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    }

    @Test("Returns empty array for outline-less PDF")
    func emptyOutlinePDF() throws {
        let url = makeTempURL("no-outline")
        defer { try? FileManager.default.removeItem(at: url) }
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 2, withOutline: false)

        let doc = try #require(PDFDocument(url: url))
        let nodes = PDFOutlineExtractor.extract(from: doc)
        #expect(nodes.isEmpty)
    }

    @Test("Walks multi-level outline tree")
    func walksMultiLevelOutline() throws {
        let url = makeTempURL("with-outline")
        defer { try? FileManager.default.removeItem(at: url) }
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: true)

        let doc = try #require(PDFDocument(url: url))
        let nodes = PDFOutlineExtractor.extract(from: doc)

        #expect(nodes.count == 1)
        let part1 = try #require(nodes.first)
        #expect(part1.label == "Part 1")
        #expect(part1.pageIndex == 0)
        #expect(part1.children.count == 2)

        let ch1 = part1.children[0]
        #expect(ch1.label == "Chapter 1")
        #expect(ch1.pageIndex == 1)

        let ch2 = part1.children[1]
        #expect(ch2.label == "Chapter 2")
        #expect(ch2.pageIndex == 2)
    }

    @Test("Flattened pre-order matches expected order")
    func flattenedTraversalOrder() throws {
        let url = makeTempURL("flatten")
        defer { try? FileManager.default.removeItem(at: url) }
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: true)

        let doc = try #require(PDFDocument(url: url))
        let labels = PDFOutlineExtractor.extract(from: doc)
            .flatMap { $0.flattened() }
            .map(\.label)
        #expect(labels == ["Part 1", "Chapter 1", "Chapter 2"])
    }
}
