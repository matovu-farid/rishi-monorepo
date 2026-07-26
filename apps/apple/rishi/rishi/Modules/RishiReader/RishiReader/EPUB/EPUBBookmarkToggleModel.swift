import Foundation
import Observation

import ReadiumShared

/// Owns the EPUB reader's bookmark UI state: the current book's bookmark set,
/// the derived `isBookmarked` flag for the location on screen, and the
/// add/remove `toggle`. Persists through the injected ``BookmarkStore`` using
/// ``EPUBBookmarkLocator`` (a wrapped Readium `Locator`).
///
/// The EPUB analogue of ``PDFBookmarkToggleModel``: where PDF keys on an integer
/// page, EPUB keys on the current top-of-viewport Readium `Locator` and defers
/// the match decision to the pure ``EPUBBookmarkMatcher`` (href + position /
/// progression-epsilon). The current locator is read lazily through a closure
/// (`currentLocator`) so the model never snapshots a stale location — the
/// toolbar reads the live `viewModel.latestLocator` at toggle/refresh time.
///
/// `@Observable @MainActor` so the toolbar button reads `isBookmarked` directly
/// in the view body (do NOT snapshot into `@State` — read the observable, so a
/// toggle/refresh repaints the SF Symbol; RESEARCH Pitfall 5). All state writes
/// stay on the main actor; the store calls are the only suspension points.
@Observable
@MainActor
public final class EPUBBookmarkToggleModel {

    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var isBookmarked = false

    private let store: any BookmarkStore
    private let bookId: BookID
    private let currentLocator: @MainActor () -> Locator?
    /// Phase 37-08 (BMK-05) — fired after a persist so the SyncEngine flags the
    /// bookmark dirty for outbound cross-device sync. `nil` in tests/previews
    /// that don't wire a sync engine.
    private let markDirty: ((BookmarkID) async -> Void)?

    public init(
        store: any BookmarkStore,
        bookId: BookID,
        currentLocator: @escaping @MainActor () -> Locator?,
        markDirty: ((BookmarkID) async -> Void)? = nil
    ) {
        self.store = store
        self.bookId = bookId
        self.currentLocator = currentLocator
        self.markDirty = markDirty
    }

    /// Reloads the book's bookmark set and recomputes `isBookmarked` for the
    /// current locator. Swallows store errors into an empty set so the toggle
    /// degrades to "not bookmarked" rather than throwing into the view.
    public func refresh() async {
        bookmarks = (try? await store.bookmarks(for: bookId)) ?? []
        if let current = currentLocator() {
            isBookmarked = EPUBBookmarkMatcher.isBookmarked(current: current, in: bookmarks)
        } else {
            isBookmarked = false
        }
    }

    /// Adds a bookmark for the current locator if absent, otherwise removes the
    /// matching one, then refreshes so `isBookmarked` reflects the new state.
    /// No-ops when there is no current locator (navigator not yet positioned).
    public func toggle() async {
        guard let current = currentLocator() else { return }
        if let existing = EPUBBookmarkMatcher.bookmark(matching: current, in: bookmarks) {
            try? await store.delete(existing.id)
            await markDirty?(existing.id)
        } else if let locator = try? EPUBBookmarkLocator(locator: current).encodedToJSONString() {
            let snippet = current.text.highlight
            let bookmark = Bookmark(bookId: bookId, locator: locator, snippet: snippet)
            try? await store.upsert(bookmark)
            await markDirty?(bookmark.id)
        }
        await refresh()
    }
}
