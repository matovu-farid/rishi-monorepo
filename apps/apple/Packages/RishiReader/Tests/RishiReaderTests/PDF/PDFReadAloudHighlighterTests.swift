#if canImport(UIKit)
import Testing
import Foundation
import PDFKit
import UIKit
@testable import RishiReader

@Suite("PDFReadAloudHighlighter")
struct PDFReadAloudHighlighterTests {

    /// Renders `text` into a single-page PDF and returns its first page. The
    /// rendered text is laid out so `PDFPage.string` round-trips the words
    /// (PDFKit's extracted string may differ in whitespace from the input,
    /// which is exactly why the locator matches whitespace-tolerantly).
    private func page(with text: String) throws -> PDFPage {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18)
            ]
            (text as NSString).draw(
                in: bounds.insetBy(dx: 36, dy: 36),
                withAttributes: attrs
            )
        }
        let doc = try #require(PDFDocument(data: data))
        return try #require(doc.page(at: 0))
    }

    @Test("Builds a selection for a paragraph present on the page")
    func selectionForPresentParagraph() throws {
        let page = try page(with: "Alice was beginning to get very tired.")
        let selection = PDFReadAloudHighlighter.selection(
            in: page, paragraph: "Alice was beginning to get very tired."
        )
        let sel = try #require(selection)
        let selectedText = (sel.string ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        #expect(selectedText.contains("beginning to get very tired"))
    }

    @Test("Returns nil for a paragraph absent from the page")
    func nilForAbsentParagraph() throws {
        let page = try page(with: "Alice was beginning to get very tired.")
        let selection = PDFReadAloudHighlighter.selection(
            in: page, paragraph: "A passage that never appears on the page."
        )
        #expect(selection == nil)
    }
}
#endif
