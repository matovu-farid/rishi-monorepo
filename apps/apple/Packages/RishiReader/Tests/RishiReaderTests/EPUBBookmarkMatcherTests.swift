import Testing
import Foundation
import RishiCore
import ReadiumShared
@testable import RishiReader

/// Phase 37 Plan 37-03 Task 1 — pins the pure href + position/progression
/// contract behind the EPUB bookmark toggle. The matcher is the one
/// host-runnable seam of this plan (the navigator/toolbar glue is verified by
/// the integrated xcodebuild gate), so these tests carry the correctness weight
/// for "is the current EPUB location bookmarked?" and "which bookmark do I
/// delete to un-bookmark this location?".
@Suite("EPUBBookmarkMatcher", .serialized)
struct EPUBBookmarkMatcherTests {

    /// Builds a Readium `Locator` for `href` with an optional integer `position`
    /// and/or `progression`.
    private func locator(
        href: String,
        position: Int? = nil,
        progression: Double? = nil
    ) throws -> Locator {
        let relative = try #require(RelativeURL(path: href))
        return Locator(
            href: relative,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: progression, position: position)
        )
    }

    /// Wraps a Readium `Locator` into an `epub-bmk-v1` bookmark row.
    private func epubBookmark(from locator: Locator) throws -> Bookmark {
        let stored = try EPUBBookmarkLocator(locator: locator).encodedToJSONString()
        return Bookmark(bookId: UUID(), locator: stored)
    }

    @Test("Same href + same integer position matches (position preferred)")
    func samePositionMatches() throws {
        let saved = try locator(href: "chapter1.xhtml", position: 12, progression: 0.5)
        // Different progression on purpose — position is the stable identity and
        // must win when both locators carry one.
        let current = try locator(href: "chapter1.xhtml", position: 12, progression: 0.9)
        let bookmarks = [try epubBookmark(from: saved)]

        #expect(EPUBBookmarkMatcher.isBookmarked(current: current, in: bookmarks))
        #expect(EPUBBookmarkMatcher.matches(current, saved))
    }

    @Test("Same href + progressions within epsilon match when positions are absent")
    func progressionEpsilonFallbackMatches() throws {
        let saved = try locator(href: "chapter2.xhtml", progression: 0.50)
        let nearby = try locator(href: "chapter2.xhtml", progression: 0.505)
        let faraway = try locator(href: "chapter2.xhtml", progression: 0.80)
        let bookmarks = [try epubBookmark(from: saved)]

        #expect(EPUBBookmarkMatcher.isBookmarked(current: nearby, in: bookmarks))
        #expect(!EPUBBookmarkMatcher.isBookmarked(current: faraway, in: bookmarks))
    }

    @Test("Different href never matches even with equal progression")
    func differentHrefNeverMatches() throws {
        let saved = try locator(href: "chapter1.xhtml", progression: 0.5)
        let otherChapter = try locator(href: "chapter9.xhtml", progression: 0.5)
        let bookmarks = [try epubBookmark(from: saved)]

        #expect(!EPUBBookmarkMatcher.isBookmarked(current: otherChapter, in: bookmarks))
        #expect(!EPUBBookmarkMatcher.matches(otherChapter, saved))
    }

    @Test("A bookmark whose locator fails to decode is ignored, not crashed on")
    func foreignOrMalformedLocatorIsIgnored() throws {
        let saved = try locator(href: "chapter1.xhtml", position: 4)
        let current = try locator(href: "chapter1.xhtml", position: 4)
        // One valid EPUB bookmark + one bogus string + one PDF-format locator.
        let pdfLocator = try PDFBookmarkLocator(page: 4, snippet: "page 4").encodedJSONString()
        let bookmarks = [
            try epubBookmark(from: saved),
            Bookmark(bookId: UUID(), locator: "not-json-at-all"),
            Bookmark(bookId: UUID(), locator: pdfLocator),
        ]

        // The valid EPUB locator still matches; the foreign rows decode to nil.
        #expect(EPUBBookmarkMatcher.isBookmarked(current: current, in: bookmarks))
        #expect(EPUBBookmarkMatcher.locator(of: bookmarks[1]) == nil)
        #expect(EPUBBookmarkMatcher.locator(of: bookmarks[2]) == nil)
    }

    @Test("bookmark(matching:) returns the matching row for removal, or nil")
    func bookmarkMatchingReturnsTheRowToDelete() throws {
        let target = try locator(href: "chapter3.xhtml", position: 7)
        let other = try locator(href: "chapter1.xhtml", position: 2)
        let targetBookmark = try epubBookmark(from: target)
        let bookmarks = [
            try epubBookmark(from: other),
            targetBookmark,
        ]
        let current = try locator(href: "chapter3.xhtml", position: 7)
        let missing = try locator(href: "chapter5.xhtml", position: 99)

        #expect(EPUBBookmarkMatcher.bookmark(matching: current, in: bookmarks)?.id == targetBookmark.id)
        #expect(EPUBBookmarkMatcher.bookmark(matching: missing, in: bookmarks) == nil)
    }
}
