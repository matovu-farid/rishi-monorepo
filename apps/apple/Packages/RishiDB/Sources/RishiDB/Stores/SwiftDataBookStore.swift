import Foundation
import SwiftData
import RishiCore
import RishiLogging

/// SwiftData-backed `BookStore`.
public final class SwiftDataBookStore: BookStore, Sendable {

    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func books(for userId: UserID) async throws -> [Book] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "books_for_user",
        ])
        do {
            return try await dbStore.read { context in
                var descriptor = FetchDescriptor<BookEntity>(
                    predicate: #Predicate { $0.userId == userId },
                    sortBy: [SortDescriptor(\BookEntity.addedAt, order: .reverse)]
                )
                descriptor.fetchLimit = nil
                return try context.fetch(descriptor).compactMap(\.bookValue)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("books(for:) failed: \(error)")
        }
    }

    public func book(_ id: BookID) async throws -> Book? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "book_by_id",
        ])
        do {
            return try await dbStore.read { context -> Book? in
                var descriptor = FetchDescriptor<BookEntity>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.bookValue
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("book(_:) failed: \(error)")
        }
    }

    public func upsert(_ book: Book) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "upsert",
        ])
        do {
            try await dbStore.write { context in
                var descriptor = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == book.id })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.update(from: book)
                } else {
                    context.insert(
                        BookEntity(
                            id: book.id,
                            userId: book.userId,
                            title: book.title,
                            author: book.author,
                            formatTypeRawValue: book.formatType.rawValue,
                            addedAt: book.addedAt,
                            openedAt: book.openedAt,
                            fileURL: book.fileURL,
                            coverPath: book.coverPath,
                            positionId: book.positionId,
                            conversationId: book.conversationId
                        )
                    )
                }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(book:) failed: \(error)")
        }
    }

    public func delete(_ id: BookID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "delete",
        ])
        do {
            try await dbStore.write { context in
                try Self.deleteAll(context, of: PositionEntity.self, matching: #Predicate { $0.bookId == id })
                try Self.deleteAll(context, of: HighlightEntity.self, matching: #Predicate { $0.bookId == id })
                try Self.deleteAll(context, of: BookmarkEntity.self, matching: #Predicate { $0.bookId == id })
                try Self.deleteAll(context, of: BookEntity.self, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(book:) failed: \(error)")
        }
    }

    private static func deleteAll<T: PersistentModel>(
        _ context: ModelContext,
        of type: T.Type,
        matching predicate: Predicate<T>
    ) throws {
        let descriptor = FetchDescriptor<T>(predicate: predicate)
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }
}
