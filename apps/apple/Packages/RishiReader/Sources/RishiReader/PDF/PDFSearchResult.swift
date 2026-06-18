import Foundation

/// Phase 37 Plan 37-04 — a single in-book PDF search hit, rendered as one row
/// in the search-results `List`.
///
/// Pure and PDFKit-free by design: it carries only a stable identity, a
/// 0-based `page` index (as returned by `PDFDocument.index(for:)` at the call
/// site), and a trimmed `snippet` string built from the matched
/// `PDFSelection.string`. Keeping the row model free of any `PDFSelection`
/// reference makes the `PDFSelection -> row` decision (the snippet clamp) a
/// pure, unit-tested function — `PDFSearchModel` holds the live selections in a
/// parallel structure so jump/highlight can still use them.
public struct PDFSearchResult: Identifiable, Hashable, Sendable {

    /// Stable per-hit identity. Defaults to a fresh `UUID` so two hits with the
    /// same page + snippet are still distinct rows in the `List`.
    public let id: UUID

    /// 0-based page index of the match, as supplied by
    /// `PDFDocument.index(for: selection.pages.first!)`.
    public let page: Int

    /// Display snippet for the row — the trimmed/clamped match string.
    public let snippet: String

    public init(id: UUID = UUID(), page: Int, snippet: String) {
        self.id = id
        self.page = page
        self.snippet = snippet
    }

    /// Builds the row snippet from a raw match string: trims surrounding
    /// whitespace/newlines and clamps to `maxLength` characters, appending a
    /// single horizontal-ellipsis when truncated.
    ///
    /// This is the one unit-tested decision of the PDF search feature. The
    /// default `maxLength` of 120 keeps a result row to roughly two lines of
    /// caption text without dominating the sheet.
    public static func snippet(from raw: String, maxLength: Int = 120) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let clamped = trimmed.prefix(maxLength)
        return "\(clamped)\u{2026}"
    }
}
