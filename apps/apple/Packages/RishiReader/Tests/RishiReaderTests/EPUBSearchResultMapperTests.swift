import Testing
import Foundation
import ReadiumShared
@testable import RishiReader

/// Phase 37 Plan 37-05 Task 1 — pins the pure `Locator -> SearchResultRow`
/// mapping behind EPUB in-book search. The mapper is the one host-runnable seam
/// of this plan (the live `publication.search` iterator + navigator jump are
/// verified by the integrated xcodebuild gate), so these tests carry the
/// correctness weight for "what does a search-result row look like?".
@Suite("EPUBSearchResultMapper", .serialized)
struct EPUBSearchResultMapperTests {

    /// Builds a Readium search-hit `Locator` for `href` with the matched
    /// `highlight` and surrounding context, plus an optional chapter `title`.
    private func locator(
        href: String,
        title: String? = nil,
        before: String? = nil,
        highlight: String? = nil,
        after: String? = nil
    ) throws -> Locator {
        let relative = try #require(RelativeURL(path: href))
        return Locator(
            href: relative,
            mediaType: .xhtml,
            title: title,
            text: Locator.Text(after: after, before: before, highlight: highlight)
        )
    }

    @Test("Subtitle contains the highlight plus trimmed surrounding context")
    func subtitleContainsHighlightAndContext() throws {
        let loc = try locator(
            href: "chapter1.xhtml",
            before: "It was the worst of ",
            highlight: "times",
            after: ", it was the age of wisdom"
        )

        let row = EPUBSearchResultMapper.row(from: loc)

        #expect(row.subtitle.contains("times"))
        #expect(row.subtitle.contains("worst of"))
        #expect(row.subtitle.contains("age of wisdom"))
        // Context exists on both sides, so both ellipses are present.
        #expect(row.subtitle.hasPrefix("\u{2026}"))
        #expect(row.subtitle.hasSuffix("\u{2026}"))
    }

    @Test("Title is the locator chapter title and is deterministic")
    func titleFromLocatorIsDeterministic() throws {
        let loc = try locator(
            href: "ch2.xhtml",
            title: "Chapter 2: A Discovery",
            highlight: "discovery"
        )

        let first = EPUBSearchResultMapper.row(from: loc)
        let second = EPUBSearchResultMapper.row(from: loc)

        #expect(first.title == "Chapter 2: A Discovery")
        // Same locator -> same title every time (id excluded; it is caller-set).
        #expect(first.title == second.title)
        #expect(first.subtitle == second.subtitle)
    }

    @Test("Title falls back to href when the locator has no chapter title")
    func titleFallsBackToHref() throws {
        let loc = try locator(href: "part3/section-final.xhtml", highlight: "end")

        let row = EPUBSearchResultMapper.row(from: loc)

        #expect(row.title.contains("section-final.xhtml"))
    }

    @Test("Empty text still yields a non-empty subtitle fallback (never crashes)")
    func emptyTextFallsBackToHref() throws {
        let loc = try locator(href: "ch5.xhtml")

        let row = EPUBSearchResultMapper.row(from: loc)

        #expect(!row.subtitle.isEmpty)
        #expect(row.subtitle.contains("ch5.xhtml"))
    }

    @Test("A long context window is clamped to maxSnippet with an ellipsis")
    func longSnippetIsClamped() throws {
        let longBefore = String(repeating: "context ", count: 40)
        let loc = try locator(
            href: "ch.xhtml",
            before: longBefore,
            highlight: "needle",
            after: longBefore
        )

        let row = EPUBSearchResultMapper.row(from: loc, maxSnippet: 40)

        #expect(row.subtitle.count <= 41) // 40 chars + trailing ellipsis
        #expect(row.subtitle.hasSuffix("\u{2026}"))
    }

    @Test("Caller-supplied id is carried onto the row")
    func idIsCarriedThrough() throws {
        let id = UUID()
        let loc = try locator(href: "ch.xhtml", highlight: "x")

        let row = EPUBSearchResultMapper.row(from: loc, id: id)

        #expect(row.id == id)
    }
}
