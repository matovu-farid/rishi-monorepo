import Foundation
import ReadiumShared

/// Phase 37 Plan 37-05 — pure mapper from a Readium `Locator` (one search hit)
/// to the engine-agnostic ``SearchResultRow`` consumed by the shared
/// ``SearchResultsView`` (built in 37-04 for the PDF reader, reused here for
/// EPUB).
///
/// This is the one host-testable seam of EPUB search: the live
/// `publication.search` iterator and the navigator jump cannot run in a unit
/// test (Readium's platform floor), but the `Locator -> SearchResultRow`
/// decision is a pure function over Readium value types and is fully covered by
/// ``EPUBSearchResultMapperTests``.
///
/// Snippet shape: Readium populates `locator.text` with the matched
/// `highlight` plus the surrounding `before` / `after` context, so the subtitle
/// reads like "...the worst of **times**, it was the age..." — the same shape
/// Apple Books shows. The snippet is whitespace-collapsed and clamped to
/// `maxSnippet` characters so a long context window never blows out the row.
///
/// `title` prefers the locator's chapter/section `title`; when Readium does not
/// supply one it falls back to the resource `href` so the row is never blank.
public enum EPUBSearchResultMapper {

    /// Builds a ``SearchResultRow`` for a single search-hit `locator`.
    ///
    /// - Parameters:
    ///   - locator: a Readium search hit; `text.highlight` is the matched run
    ///     and `text.before` / `text.after` are the surrounding context.
    ///   - id: the row id. Callers (``EPUBSearchModel``) pass a stable id keyed
    ///     to the locator's position in the results array so a tapped row can be
    ///     resolved back to its `Locator` for the jump. Defaults to a fresh
    ///     `UUID` for standalone/preview use.
    ///   - maxSnippet: the maximum subtitle length before clamping with a
    ///     trailing ellipsis. Defaults to 120, matching the PDF snippet clamp.
    public static func row(
        from locator: Locator,
        id: UUID = UUID(),
        maxSnippet: Int = 120
    ) -> SearchResultRow {
        let before = locator.text.before ?? ""
        let highlight = locator.text.highlight ?? ""
        let after = locator.text.after ?? ""

        let snippet = clampedSnippet(
            before: before,
            highlight: highlight,
            after: after,
            maxLength: maxSnippet
        )

        let href = locator.href.string
        let title = locator.title?.trimmedNonEmpty ?? href.trimmedNonEmpty ?? "Match"
        let subtitle = snippet.trimmedNonEmpty ?? href.trimmedNonEmpty ?? "Match"

        return SearchResultRow(id: id, title: title, subtitle: subtitle)
    }

    /// Joins the before/highlight/after context into a single collapsed-
    /// whitespace snippet, wraps it in leading/trailing ellipses when context is
    /// present, and clamps to `maxLength` characters.
    private static func clampedSnippet(
        before: String,
        highlight: String,
        after: String,
        maxLength: Int
    ) -> String {
        let core = collapseWhitespace(before + highlight + after)
        guard !core.isEmpty else { return "" }

        // Only show the ellipses that indicate truncated context actually
        // exists on that side.
        let leading = before.trimmedNonEmpty != nil ? "\u{2026}" : ""
        let trailing = after.trimmedNonEmpty != nil ? "\u{2026}" : ""
        let decorated = leading + core + trailing

        guard decorated.count > maxLength else { return decorated }
        let clamped = decorated.prefix(maxLength)
        return clamped.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Collapses runs of whitespace/newlines to single spaces and trims the
    /// ends, so multi-line resource text reads as one tidy line.
    private static func collapseWhitespace(_ string: String) -> String {
        string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private extension String {
    /// The receiver trimmed of surrounding whitespace, or `nil` when the result
    /// is empty — lets the mapper fall back deterministically.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
