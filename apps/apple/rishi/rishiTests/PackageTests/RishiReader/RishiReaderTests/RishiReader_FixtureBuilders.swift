@testable import rishi
import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Programmatic PDF fixtures for reader tests. Keeps the repo free of
/// binary blobs and gives each test deterministic, isolated input.
enum RishiReader_FixtureBuilders {

    enum FixtureError: Error {
        case cannotBuildPage
        case cannotEncode
    }

    /// Writes a single-page PDF (240x320).
    static func writeTinyPDF(to url: URL) throws {
        try writeMultiPagePDF(to: url, pageCount: 1, withOutline: false)
    }

    /// Writes a multi-page PDF. Each page is solid blue with "Page N" text.
    /// If `withOutline` is true, adds a 2-level outline:
    ///   - "Part 1" → page 0
    ///     - "Chapter 1" → page 1
    ///     - "Chapter 2" → page 2 (if pageCount >= 3)
    static func writeMultiPagePDF(
        to url: URL,
        pageCount: Int,
        withOutline: Bool
    ) throws {
        let doc = PDFDocument()
        for i in 0..<pageCount {
            let page = try renderPage(label: "Page \(i + 1)")
            doc.insert(page, at: i)
        }

        if withOutline, pageCount >= 1 {
            let root = PDFOutline()
            let part1 = PDFOutline()
            part1.label = "Part 1"
            part1.destination = PDFDestination(page: doc.page(at: 0)!, at: .zero)
            root.insertChild(part1, at: 0)

            if pageCount >= 2 {
                let ch1 = PDFOutline()
                ch1.label = "Chapter 1"
                ch1.destination = PDFDestination(page: doc.page(at: 1)!, at: .zero)
                part1.insertChild(ch1, at: 0)
            }
            if pageCount >= 3 {
                let ch2 = PDFOutline()
                ch2.label = "Chapter 2"
                ch2.destination = PDFDestination(page: doc.page(at: 2)!, at: .zero)
                part1.insertChild(ch2, at: 1)
            }
            doc.outlineRoot = root
        }

        guard let data = doc.dataRepresentation() else { throw FixtureError.cannotEncode }
        try data.write(to: url, options: .atomic)
    }

    private static func renderPage(label: String) throws -> PDFPage {
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
            label.draw(in: CGRect(x: 0, y: 140, width: 240, height: 40), withAttributes: attrs)
        }
        guard let page = PDFPage(image: image) else { throw FixtureError.cannotBuildPage }
        return page
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
        label.draw(in: NSRect(x: 0, y: 140, width: 240, height: 40), withAttributes: attrs)
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { throw FixtureError.cannotBuildPage }
        return page
        #endif
    }
}
