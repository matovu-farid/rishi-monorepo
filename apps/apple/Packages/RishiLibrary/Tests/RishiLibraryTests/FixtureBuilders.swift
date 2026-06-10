import Foundation
import PDFKit
import ReadiumZIPFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Test-only helpers that build tiny on-disk fixtures programmatically.
///
/// Generated in a per-test temp directory so we never commit binary blobs.
enum FixtureBuilders {

    /// Writes a 1-page PDF at `url` containing a single SF Symbol page.
    static func writeTinyPDF(to url: URL) throws {
        let pdfDoc = PDFDocument()
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 28),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            "PDF\nFIXTURE".draw(in: CGRect(x: 0, y: 110, width: 240, height: 100), withAttributes: attrs)
        }
        guard let page = PDFPage(image: image) else { throw FixtureError.cannotBuildPDFPage }
        #else
        let image = NSImage(size: NSSize(width: 240, height: 320))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 320).fill()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para
        ]
        "PDF\nFIXTURE".draw(in: NSRect(x: 0, y: 110, width: 240, height: 100), withAttributes: attrs)
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { throw FixtureError.cannotBuildPDFPage }
        #endif
        pdfDoc.insert(page, at: 0)
        guard let data = pdfDoc.dataRepresentation() else { throw FixtureError.cannotEncodePDF }
        try data.write(to: url, options: .atomic)
    }

    /// Writes a minimal EPUB 3 at `url`:
    /// - `mimetype` (uncompressed, must be first entry)
    /// - `META-INF/container.xml`
    /// - `OEBPS/content.opf` declaring a cover image
    /// - `OEBPS/cover.png` (1x1 red pixel)
    ///
    /// ReadiumZIPFoundation 3.x made `Archive` an actor; init and `addEntry` are now `async`,
    /// so this builder is `async throws`.
    static func writeTinyEPUB(to url: URL, withCover: Bool = true) async throws {
        // Delete any existing file at url (Archive(creating:) requires a fresh path).
        try? FileManager.default.removeItem(at: url)
        let archive: Archive
        do {
            archive = try await Archive(url: url, accessMode: .create)
        } catch {
            throw FixtureError.cannotCreateArchive
        }

        // 1) mimetype (uncompressed)
        let mimetype = Data("application/epub+zip".utf8)
        try await archive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetype.count),
            compressionMethod: .none,
            provider: { @Sendable position, size in
                mimetype.subdata(in: Int(position)..<Int(position) + size)
            }
        )

        // 2) container.xml
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try await addEntry(archive: archive, path: "META-INF/container.xml", data: Data(container.utf8))

        // 3) content.opf with cover meta
        let coverMeta = withCover ? "<meta name=\"cover\" content=\"cover-image\"/>" : ""
        let coverManifest = withCover ? "<item id=\"cover-image\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>" : ""
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">test-book-id</dc:identifier>
            <dc:title>Fixture Title</dc:title>
            <dc:language>en</dc:language>
            \(coverMeta)
          </metadata>
          <manifest>
            \(coverManifest)
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          </manifest>
          <spine>
            <itemref idref="nav"/>
          </spine>
        </package>
        """
        try await addEntry(archive: archive, path: "OEBPS/content.opf", data: Data(opf.utf8))

        // 4) cover.png (1x1 red pixel) — only if we want a cover
        if withCover {
            try await addEntry(archive: archive, path: "OEBPS/cover.png", data: tinyRedPNG())
        }

        // 5) nav.xhtml stub
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Nav</title></head>
        <body><nav epub:type="toc"><ol><li><a href="nav.xhtml">Start</a></li></ol></nav></body>
        </html>
        """
        try await addEntry(archive: archive, path: "OEBPS/nav.xhtml", data: Data(nav.utf8))
    }

    private static func addEntry(archive: Archive, path: String, data: Data) async throws {
        try await archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { @Sendable position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }

    /// 1x1 red PNG (8-bit RGBA), hand-encoded so we don't need a real image rendered.
    private static func tinyRedPNG() -> Data {
        // PNG signature + IHDR + IDAT + IEND for a 1x1 red opaque pixel.
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x5B, 0xB6, 0x33,
            0x2A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        return Data(bytes)
    }

    enum FixtureError: Error {
        case cannotBuildPDFPage
        case cannotEncodePDF
        case cannotCreateArchive
    }
}
