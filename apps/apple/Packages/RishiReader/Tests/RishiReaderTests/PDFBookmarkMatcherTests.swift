import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// Phase 37 Plan 37-02 Task 1 — pins the pure page-equality contract behind the
/// PDF bookmark toggle. The matcher is the one host-runnable seam of this plan
/// (the toolbar/sheet glue is verified by the integrated xcodebuild gate), so
/// these tests carry the correctness weight for "is the current page
/// bookmarked?" and "which bookmark do I delete to un-bookmark this page?".
@Suite("PDFBookmarkMatcher", .serialized)
struct PDFBookmarkMatcherTests {

    /// Builds a PDF bookmark whose locator decodes to `page`.
    private func pdfBookmark(page: Int, snippet: String? = nil) throws -> Bookmark {
        let locator = try PDFBookmarkLocator(page: page, snippet: snippet).encodedJSONString()
        return Bookmark(bookId: UUID(), locator: locator, snippet: snippet)
    }

    @Test("isBookmarked is true for a page present in the set, false otherwise")
    func isBookmarkedMatchesPageEquality() throws {
        let bookmarks = [
            try pdfBookmark(page: 3),
            try pdfBookmark(page: 7),
            try pdfBookmark(page: 12),
        ]

        #expect(PDFBookmarkMatcher.isBookmarked(page: 7, in: bookmarks))
        #expect(PDFBookmarkMatcher.isBookmarked(page: 3, in: bookmarks))
        #expect(PDFBookmarkMatcher.isBookmarked(page: 12, in: bookmarks))
        #expect(!PDFBookmarkMatcher.isBookmarked(page: 5, in: bookmarks))
        #expect(!PDFBookmarkMatcher.isBookmarked(page: 0, in: bookmarks))
    }

    @Test("A non-PDF or malformed locator is ignored, not crashed on")
    func foreignLocatorIsIgnored() throws {
        // One valid PDF bookmark, one bogus string, one EPUB-format locator.
        let epubLocator = try EPUBBookmarkLocator(
            readiumLocator: #"{"href":"chapter1.xhtml","locations":{"position":4}}"#
        ).encodedJSONString()
        let bookmarks = [
            try pdfBookmark(page: 7),
            Bookmark(bookId: UUID(), locator: "not-json-at-all"),
            Bookmark(bookId: UUID(), locator: epubLocator),
        ]

        // The PDF page still matches; the foreign rows simply decode to nil.
        #expect(PDFBookmarkMatcher.isBookmarked(page: 7, in: bookmarks))
        #expect(!PDFBookmarkMatcher.isBookmarked(page: 4, in: bookmarks))
        #expect(PDFBookmarkMatcher.page(of: bookmarks[1]) == nil)
        #expect(PDFBookmarkMatcher.page(of: bookmarks[2]) == nil)
    }

    @Test("bookmark(forPage:) returns the matching bookmark for removal, or nil")
    func bookmarkForPageReturnsTheRowToDelete() throws {
        let target = try pdfBookmark(page: 7, snippet: "page seven")
        let bookmarks = [
            try pdfBookmark(page: 3),
            target,
            try pdfBookmark(page: 12),
        ]

        let found = PDFBookmarkMatcher.bookmark(forPage: 7, in: bookmarks)
        #expect(found?.id == target.id)
        #expect(PDFBookmarkMatcher.bookmark(forPage: 99, in: bookmarks) == nil)
    }
}
