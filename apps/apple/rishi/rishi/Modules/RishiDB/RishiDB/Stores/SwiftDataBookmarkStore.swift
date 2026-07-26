import Foundation
import SwiftData



/// SwiftData-backed `BookmarkStore`.
public final class SwiftDataBookmarkStore: BookmarkStore, Sendable {

    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "bookmarks_for_book",
        ])
        do {
            return try await dbStore.read { context in
                var descriptor = FetchDescriptor<BookmarkEntity>(
                    predicate: #Predicate { $0.bookId == bookId },
                    sortBy: [SortDescriptor(\BookmarkEntity.createdAt)]
                )
                descriptor.fetchLimit = nil
                return try context.fetch(descriptor).map(\.bookmarkValue)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("bookmarks(for:) failed: \(error)")
        }
    }

    public func bookmark(_ id: BookmarkID) async throws -> Bookmark? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "bookmark_by_id",
        ])
        do {
            return try await dbStore.read { context -> Bookmark? in
                var descriptor = FetchDescriptor<BookmarkEntity>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.bookmarkValue
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("bookmark(_:) failed: \(error)")
        }
    }

    public func upsert(_ bookmark: Bookmark) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "upsert",
        ])
        do {
            try await dbStore.write { context in
                var descriptor = FetchDescriptor<BookmarkEntity>(predicate: #Predicate { $0.id == bookmark.id })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.update(from: bookmark)
                } else {
                    context.insert(
                        BookmarkEntity(
                            id: bookmark.id,
                            bookId: bookmark.bookId,
                            locator: bookmark.locator,
                            label: bookmark.label,
                            snippet: bookmark.snippet,
                            createdAt: bookmark.createdAt
                        )
                    )
                }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(bookmark:) failed: \(error)")
        }
    }

    public func delete(_ id: BookmarkID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "delete",
        ])
        do {
            try await dbStore.write { context in
                try Self.deleteAll(context, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(bookmark:) failed: \(error)")
        }
    }

    private static func deleteAll(_ context: ModelContext, matching predicate: Predicate<BookmarkEntity>) throws {
        let descriptor = FetchDescriptor<BookmarkEntity>(predicate: predicate)
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }
}
