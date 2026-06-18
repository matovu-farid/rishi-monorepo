import Foundation
import RishiCore

/// Pure, PDFKit-free predicate that decides whether a PDF page is bookmarked.
///
/// The reader screen holds a `[Bookmark]` set scoped to the current book and a
/// current page index. `PDFBookmarkMatcher` is the single source of truth for
/// the "is this page bookmarked?" question, kept as a pure function over page
/// equality so it can be unit-tested on the host without instantiating PDFKit.
///
/// Each `Bookmark.locator` is a `pdf-bmk-v1` JSON string (see
/// ``PDFBookmarkLocator``). Bookmarks whose locator fails to decode — a
/// malformed string or an EPUB (`epub-bmk-v1`) locator that rode through the
/// same store — are silently ignored rather than crashed on, so a mixed-format
/// bookmark set never breaks the PDF toggle.
public enum PDFBookmarkMatcher {

    /// Decodes the PDF page index from a bookmark's locator, or `nil` when the
    /// locator is malformed or belongs to another reader engine.
    public static func page(of bookmark: Bookmark) -> Int? {
        (try? PDFBookmarkLocator.decoded(fromJSONString: bookmark.locator))?.page
    }

    /// `true` when any bookmark in `bookmarks` decodes to `page`.
    public static func isBookmarked(page: Int, in bookmarks: [Bookmark]) -> Bool {
        bookmarks.contains { self.page(of: $0) == page }
    }

    /// The first bookmark whose locator decodes to `page`, for removal, or `nil`.
    public static func bookmark(forPage page: Int, in bookmarks: [Bookmark]) -> Bookmark? {
        bookmarks.first { self.page(of: $0) == page }
    }
}
