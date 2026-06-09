import Foundation
import Testing
@testable import RishiLibrary

@Suite(.serialized)
struct CoverExtractorTests {

    private func makeTempDir(_ label: String) -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("CoverExtractorTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func pdfExtractor_returnsNonNilDataForValidPDF() async throws {
        let dir = makeTempDir("pdf-happy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdfURL = dir.appendingPathComponent("fixture.pdf")
        try FixtureBuilders.writeTinyPDF(to: pdfURL)

        let extractor = PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160))
        let data = await extractor.extractCover(from: pdfURL)

        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
        // PNG signature check
        if let d = data, d.count >= 8 {
            #expect(d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47)
        }
    }

    @Test
    func pdfExtractor_returnsNilForMissingFile() async throws {
        let dir = makeTempDir("pdf-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.pdf")

        let extractor = PDFKitCoverExtractor()
        let data = await extractor.extractCover(from: missing)
        #expect(data == nil)
    }

    @Test
    func epubExtractor_returnsNonNilForEPUBWithCover() async throws {
        let dir = makeTempDir("epub-happy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epubURL = dir.appendingPathComponent("fixture.epub")
        try FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: true)

        let extractor = EpubCoverExtractor()
        let data = await extractor.extractCover(from: epubURL)
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test
    func epubExtractor_returnsNilForEPUBWithoutCover() async throws {
        let dir = makeTempDir("epub-nocover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epubURL = dir.appendingPathComponent("fixture.epub")
        try FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: false)

        let extractor = EpubCoverExtractor()
        let data = await extractor.extractCover(from: epubURL)
        #expect(data == nil)
    }

    @Test
    func epubExtractor_returnsNilForMissingFile() async throws {
        let dir = makeTempDir("epub-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.epub")

        let extractor = EpubCoverExtractor()
        let data = await extractor.extractCover(from: missing)
        #expect(data == nil)
    }
}
