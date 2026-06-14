import Foundation
import PDFKit
import RishiCore

/// Per-page PDFKit text extractor. `page` in the result is the 1-based PDF
/// page index (matches the visible page number the reader shows).
///
/// Strategy:
///   1. Open via `PDFDocument(url:)`. Unreadable -> return `[]`.
///   2. For each page 0..<pageCount, read `page.string ?? ""`.
///   3. Paragraph-chunk via `RishiCore.ParagraphChunker.chunk(_:)`.
///   4. Emit one `(page: pageIndex + 1, text: chunk)` row per non-empty chunk.
public struct PdfTextExtractor: PerBookTextExtractor {
    public init() {}

    public func extractParagraphs(
        from fileURL: URL
    ) async throws -> [(page: Int, text: String)] {
        guard let document = PDFDocument(url: fileURL) else { return [] }
        var result: [(page: Int, text: String)] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let raw = page.string ?? ""
            let chunks = ParagraphChunker.chunk(raw)
            for chunk in chunks where !chunk.isEmpty {
                result.append((page: pageIndex + 1, text: chunk))
            }
        }
        return result
    }
}
