import Foundation

public protocol BookmarkStore: Sendable {
    func bookmarks(for bookId: BookID) async throws -> [Bookmark]
    func bookmark(_ id: BookmarkID) async throws -> Bookmark?
    func upsert(_ bookmark: Bookmark) async throws
    func delete(_ id: BookmarkID) async throws
}
