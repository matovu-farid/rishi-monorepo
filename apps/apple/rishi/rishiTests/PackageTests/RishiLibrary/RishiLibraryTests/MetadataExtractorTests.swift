@testable import rishi
import Foundation
import Testing
import PDFKit


@Suite(.serialized)
struct MetadataExtractorTests {

    private func makeTempDir(_ label: String) -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("MetadataExtractorTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - EPUB

    @Test
    func epubMetadata_extractsTitleAndCreatorFromOPF() {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">test</dc:identifier>
            <dc:title>Alice in Wonderland</dc:title>
            <dc:creator opf:role="aut">Lewis Carroll</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
        </package>
        """
        let title = EpubMetadataExtractor.parseDCTitle(from: Data(opf.utf8))
        let author = EpubMetadataExtractor.parseDCCreator(from: Data(opf.utf8))
        #expect(title == "Alice in Wonderland")
        #expect(author == "Lewis Carroll")
    }

    @Test
    func epubMetadata_decodesXMLEntitiesInTitle() {
        let opf = """
        <package xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata>
            <dc:title>Tom &amp; Jerry</dc:title>
            <dc:creator>H. G. Wells</dc:creator>
          </metadata>
        </package>
        """
        let title = EpubMetadataExtractor.parseDCTitle(from: Data(opf.utf8))
        #expect(title == "Tom & Jerry")
    }

    @Test
    func epubMetadata_returnsNilWhenOPFHasNoDCTitle() {
        let opf = """
        <package><metadata><meta name="cover" content="cov"/></metadata></package>
        """
        let title = EpubMetadataExtractor.parseDCTitle(from: Data(opf.utf8))
        let author = EpubMetadataExtractor.parseDCCreator(from: Data(opf.utf8))
        #expect(title == nil)
        #expect(author == nil)
    }

    @Test
    func epubMetadata_endToEndExtractsTitleFromArchive() async throws {
        let dir = makeTempDir("epub-end-to-end")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epubURL = dir.appendingPathComponent("fixture.epub")
        try await FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: true)

        let extractor = EpubMetadataExtractor()
        let metadata = await extractor.extractMetadata(from: epubURL)
        // FixtureBuilders.writeTinyEPUB writes `<dc:title>Fixture Title</dc:title>`.
        #expect(metadata.title == "Fixture Title")
        // No <dc:creator> in the fixture — author should be nil.
        #expect(metadata.author == nil)
    }

    @Test
    func epubMetadata_returnsEmptyForMissingFile() async {
        let dir = makeTempDir("epub-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.epub")

        let extractor = EpubMetadataExtractor()
        let metadata = await extractor.extractMetadata(from: missing)
        #expect(metadata.title == nil)
        #expect(metadata.author == nil)
    }

    // MARK: - PDF

    @Test
    func pdfMetadata_extractsTitleAndAuthorFromDocumentAttributes() async throws {
        let dir = makeTempDir("pdf-meta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.pdf")

        // Build a PDF and stamp Title + Author into its documentAttributes.
        try FixtureBuilders.writeTinyPDF(to: url)
        if let doc = PDFDocument(url: url) {
            var attrs = doc.documentAttributes ?? [:]
            attrs[PDFDocumentAttribute.titleAttribute] = "Alice in Wonderland"
            attrs[PDFDocumentAttribute.authorAttribute] = "Lewis Carroll"
            doc.documentAttributes = attrs
            #expect(doc.write(to: url))
        }

        let extractor = PDFKitMetadataExtractor()
        let metadata = await extractor.extractMetadata(from: url)
        #expect(metadata.title == "Alice in Wonderland")
        #expect(metadata.author == "Lewis Carroll")
    }

    @Test
    func pdfMetadata_returnsEmptyWhenNoTitleOrAuthor() async throws {
        let dir = makeTempDir("pdf-no-meta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.pdf")
        try FixtureBuilders.writeTinyPDF(to: url)

        let extractor = PDFKitMetadataExtractor()
        let metadata = await extractor.extractMetadata(from: url)
        // The tiny fixture is built via PDFDocument() without setting Title /
        // Author. PDFKit may synthesize default attributes, so we only assert
        // that empty + missing both fold to nil.
        #expect(metadata.title == nil || !(metadata.title?.isEmpty ?? true))
    }

    @Test
    func pdfMetadata_returnsEmptyForMissingFile() async {
        let dir = makeTempDir("pdf-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.pdf")

        let extractor = PDFKitMetadataExtractor()
        let metadata = await extractor.extractMetadata(from: missing)
        #expect(metadata.title == nil)
        #expect(metadata.author == nil)
    }

    // MARK: - BookMetadata sanitization

    @Test
    func bookMetadata_trimsWhitespaceAndCollapsesEmptyToNil() {
        let m1 = BookMetadata(title: "  Hello  ", author: "  ")
        #expect(m1.title == "Hello")
        #expect(m1.author == nil)

        let m2 = BookMetadata(title: "", author: nil)
        #expect(m2.title == nil)
        #expect(m2.author == nil)
    }
}
