import Foundation

/// Resolves the raw text of a book into ordered `(page, text)` paragraph
/// rows that the `IndexBuilder` (Plan 25-05) embeds + persists.
///
/// One conformer per supported format:
///   - `PdfTextExtractor` — PDFKit per-page `page.string`.
///   - `EpubTextExtractor` — ReadiumZIPFoundation OPF spine walk;
///     `page` is the 1-based reading-order position (closes RESEARCH OQ-1).
///
/// The hook (`RishiSearchIndexingHook`) routes to a conformer by lowercase
/// file extension (`"pdf"`, `"epub"`).
public protocol PerBookTextExtractor: Sendable {
    /// Extract paragraphs from the file at `fileURL`.
    ///
    /// - Returns: ordered `(page, text)` rows. Empty input or unreadable
    ///   files MUST return `[]` rather than throwing — the hook treats
    ///   "no paragraphs" as a degenerate but valid index.
    /// - Throws: only when the underlying IO surface (PDFKit, ZIP) raises a
    ///   non-trivial error worth propagating to the indexing status sidecar.
    func extractParagraphs(from fileURL: URL) async throws -> [(page: Int, text: String)]
}
