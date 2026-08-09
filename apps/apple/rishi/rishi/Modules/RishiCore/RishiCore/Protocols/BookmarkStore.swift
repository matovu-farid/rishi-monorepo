import Foundation

public protocol BookmarkStore: Sendable {
    func bookmarks(for bookId: BookID) async throws -> [Bookmark]
    func bookmark(_ id: BookmarkID) async throws -> Bookmark?
    func upsert(_ bookmark: Bookmark) async throws
    func delete(_ id: BookmarkID) async throws
    func deleteIfUnchanged(_ id: BookmarkID, matching expected: Bookmark?) async throws -> Bool
}

public extension BookmarkStore {
    func deleteIfUnchanged(_ id: BookmarkID, matching expected: Bookmark?) async throws -> Bool {
        guard try await bookmark(id) == expected else { return false }
        try await delete(id)
        return true
    }
}
