import Foundation


public actor InMemoryBookmarkStore: BookmarkStore {
    private var storage: [BookmarkID: Bookmark] = [:]

    public init(initial: [Bookmark] = []) {
        for b in initial { storage[b.id] = b }
    }

    public func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
        storage.values
            .filter { $0.bookId == bookId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func bookmark(_ id: BookmarkID) async throws -> Bookmark? {
        storage[id]
    }

    public func upsert(_ bookmark: Bookmark) async throws {
        storage[bookmark.id] = bookmark
    }

    public func delete(_ id: BookmarkID) async throws {
        storage.removeValue(forKey: id)
    }
}
