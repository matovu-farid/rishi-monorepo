import Foundation


public func assertBookmarkStoreConformance(_ store: any BookmarkStore) async throws {
    let bookA = UUID()
    let bookB = UUID()

    let empty = try await store.bookmarks(for: bookA)
    guard empty.isEmpty else {
        throw RishiTestingError.expected("bookmarks initially empty, got \(empty.count)")
    }

    let b1 = Bookmark.fixture(bookId: bookA, label: "alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await store.upsert(b1)
    let got = try await store.bookmark(b1.id)
    guard got == b1 else {
        throw RishiTestingError.expected("bookmark(_:) mismatch")
    }

    try await store.upsert(b1) // idempotent
    let aOnly = try await store.bookmarks(for: bookA)
    guard aOnly.count == 1 else {
        throw RishiTestingError.expected("re-upsert produced \(aOnly.count) rows")
    }

    let b2 = Bookmark.fixture(bookId: bookB, label: "beta", createdAt: Date(timeIntervalSince1970: 1_700_000_500))
    try await store.upsert(b2)
    let bOnly = try await store.bookmarks(for: bookB)
    guard bOnly.count == 1, bOnly.first?.label == "beta" else {
        throw RishiTestingError.expected("book scoping failed")
    }

    // Ordering: createdAt ascending within a book.
    let b3 = Bookmark.fixture(bookId: bookA, label: "later", createdAt: Date(timeIntervalSince1970: 1_700_001_000))
    let b0 = Bookmark.fixture(bookId: bookA, label: "earlier", createdAt: Date(timeIntervalSince1970: 1_699_999_000))
    try await store.upsert(b3)
    try await store.upsert(b0)
    let ordered = try await store.bookmarks(for: bookA)
    let createdAts = ordered.map(\.createdAt)
    guard createdAts == createdAts.sorted() else {
        throw RishiTestingError.expected("bookmarks not sorted by createdAt ascending")
    }

    try await store.delete(b1.id)
    let postDelete = try await store.bookmark(b1.id)
    guard postDelete == nil else {
        throw RishiTestingError.expected("bookmark not deleted")
    }
}
