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
        try await FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: true)

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
        try await FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: false)

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

    /// Regression: real-world EPUB 2 OPFs (Calibre, Gutenberg ebookmaker,
    /// Purple Cow, etc.) emit `<item>` attributes with `href` BEFORE `id`.
    /// The previous regex only matched `id`-first and silently dropped these
    /// books to the purple-gradient placeholder.
    @Test
    func parseCoverHref_handlesEPUB2WithHrefBeforeId() throws {
        // Snippet copied verbatim from a Project Gutenberg ebookmaker OPF.
        let opf = """
        <?xml version='1.0' encoding='UTF-8'?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Sample</dc:title>
            <meta name="cover" content="id-6625678902257115245"/>
          </metadata>
          <manifest>
            <item href="1751655520501062500_cover.jpg" id="id-6625678902257115245" media-type="image/jpeg"/>
            <item href="toc.ncx" id="ncx" media-type="application/x-dtbncx+xml"/>
          </manifest>
        </package>
        """
        let href = EpubCoverExtractor.parseCoverHref(from: Data(opf.utf8))
        #expect(href == "1751655520501062500_cover.jpg")
    }

    /// Companion: classic EPUB 2 with `id` BEFORE `href` must still parse.
    @Test
    func parseCoverHref_handlesEPUB2WithIdBeforeHref() throws {
        let opf = """
        <?xml version='1.0' encoding='UTF-8'?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="images/cover.jpg" media-type="image/jpeg"/>
          </manifest>
        </package>
        """
        let href = EpubCoverExtractor.parseCoverHref(from: Data(opf.utf8))
        #expect(href == "images/cover.jpg")
    }
}
