import Foundation
import PDFKit

/// A private PDFKit document and immutable page-range cache for narration.
/// PDFKit and the cache are accessed together under one synchronous lock;
/// callers receive value ranges and tokenize after this method returns.
public final class PDFNarrationParagraphMap: @unchecked Sendable {
    private let lock = NSLock()
    private let document: PDFDocument?
    private var cache: [Int: CachedPage] = [:]

    private struct CachedPage {
        let text: String
        let result: PDFReadAloudParagraphs.ParagraphRangeResult
    }

    public init(documentURL: URL) {
        document = PDFDocument(url: documentURL)
    }

    /// `page` is the 1-based page number from a Readium PDF locator.
    public func paragraphRanges(page: Int, pageText: String) -> PDFReadAloudParagraphs.ParagraphRangeResult {
        lock.withLock {
            guard page > 0, let document, let pdfPage = document.page(at: page - 1) else {
                return .unavailable
            }
            if let cached = cache[page], cached.text == pageText {
                return cached.result
            }
            guard pdfPage.string == pageText else { return .unavailable }
            let result = PDFReadAloudParagraphs.paragraphRanges(from: pdfPage, pageText: pageText)
            cache[page] = CachedPage(text: pageText, result: result)
            return result
        }
    }
}
