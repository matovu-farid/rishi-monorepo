import Foundation


/// Owns the PDF reader's bookmark UI state: the current book's bookmark set,
/// the derived `isBookmarked` flag for the page on screen, and the add/remove
/// `toggle`. Persists through the injected ``BookmarkStore`` using
/// ``PDFBookmarkLocator`` (page + optional snippet).
///
/// `@Observable @MainActor` so the toolbar button reads `isBookmarked` directly
/// in the view body (do NOT snapshot into `@State` — read the observable, so a
/// toggle/refresh repaints the SF Symbol). All state writes stay on the main
/// actor; the store calls are the only suspension points.
@Observable
@MainActor
public final class PDFBookmarkToggleModel {

    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var isBookmarked = false

    private let store: any BookmarkStore
    private let bookId: BookID
    /// Phase 37-08 (BMK-05) — fired after a persist so the SyncEngine flags the
    /// bookmark dirty for outbound cross-device sync. `nil` in tests/previews
    /// that don't wire a sync engine.
    private let markDirty: ((BookmarkID) async -> Void)?

    public init(
        store: any BookmarkStore,
        bookId: BookID,
        markDirty: ((BookmarkID) async -> Void)? = nil
    ) {
        self.store = store
        self.bookId = bookId
        self.markDirty = markDirty
    }

    /// Reloads the book's bookmark set and recomputes `isBookmarked` for
    /// `currentPage`. Swallows store errors into an empty set so the toggle
    /// degrades to "not bookmarked" rather than throwing into the view.
    public func refresh(currentPage: Int) async {
        bookmarks = (try? await store.bookmarks(for: bookId)) ?? []
        isBookmarked = PDFBookmarkMatcher.isBookmarked(page: currentPage, in: bookmarks)
    }

    /// Adds a bookmark for `currentPage` if absent, otherwise removes the
    /// existing one, then refreshes so `isBookmarked` reflects the new state.
    public func toggle(currentPage: Int, snippet: String?) async {
        if let existing = PDFBookmarkMatcher.bookmark(forPage: currentPage, in: bookmarks) {
            try? await store.delete(existing.id)
            await markDirty?(existing.id)
        } else if let locator = try? PDFBookmarkLocator(page: currentPage, snippet: snippet).encodedJSONString() {
            let bookmark = Bookmark(bookId: bookId, locator: locator, snippet: snippet)
            try? await store.upsert(bookmark)
            await markDirty?(bookmark.id)
        }
        await refresh(currentPage: currentPage)
    }
}
