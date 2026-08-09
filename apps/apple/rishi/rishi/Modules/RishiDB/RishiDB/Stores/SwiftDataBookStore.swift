import Foundation
import SwiftData



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
                            conversationId: book.conversationId,
                            chapterIndexContentVersion: book.chapterIndexContentVersion
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
                let indexIDs = try context.fetch(FetchDescriptor<ChapterIndexEntity>(predicate: #Predicate { $0.bookID == id })).map(\.id)
                for indexID in indexIDs {
                    try Self.deleteAll(context, of: ChapterSummaryEntity.self, matching: #Predicate { $0.indexID == indexID })
                }
                try Self.deleteAll(context, of: ChapterIndexEntity.self, matching: #Predicate { $0.bookID == id })
                try Self.deleteAll(context, of: BookEntity.self, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(book:) failed: \(error)")
        }
    }

    public func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool {
        try await dbStore.write { context in
            var descriptor = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else { return expected == nil }
            guard entity.bookValue == expected else { return false }
            try Self.deleteAll(context, of: PositionEntity.self, matching: #Predicate { $0.bookId == id })
            try Self.deleteAll(context, of: HighlightEntity.self, matching: #Predicate { $0.bookId == id })
            try Self.deleteAll(context, of: BookmarkEntity.self, matching: #Predicate { $0.bookId == id })
            let indexIDs = try context.fetch(FetchDescriptor<ChapterIndexEntity>(predicate: #Predicate { $0.bookID == id })).map(\.id)
            for indexID in indexIDs {
                try Self.deleteAll(context, of: ChapterSummaryEntity.self, matching: #Predicate { $0.indexID == indexID })
            }
            try Self.deleteAll(context, of: ChapterIndexEntity.self, matching: #Predicate { $0.bookID == id })
            try Self.deleteAll(context, of: BookEntity.self, matching: #Predicate { $0.id == id })
            return true
        }
    }

    public func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? {
        try await dbStore.read { context in
            var descriptor = FetchDescriptor<ChapterIndexEntity>(predicate: #Predicate { $0.bookID == bookID && $0.contentVersion == contentVersion })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first,
                  let status = ChapterIndexStatus(rawValue: entity.statusRawValue) else { return nil }
            let indexID = entity.id
            let summaries = try context.fetch(FetchDescriptor<ChapterSummaryEntity>(predicate: #Predicate { $0.indexID == indexID }))
                .sorted { ($0.sourcePosition ?? 0) < ($1.sourcePosition ?? 0) }
            return ChapterIndex(id: entity.id, bookID: entity.bookID, contentVersion: entity.contentVersion, status: status, modelIdentifier: entity.modelIdentifier, modelVersion: entity.modelVersion, progress: .init(completed: entity.completedCount, total: entity.totalCount), chapters: summaries.map { .init(id: $0.chapterID, name: $0.name, summary: $0.summary, sourcePosition: $0.sourcePosition ?? 0) }, errorMessage: entity.errorMessage, createdAt: entity.createdAt, updatedAt: entity.updatedAt)
        }
    }

    public func upsertChapterIndex(_ index: ChapterIndex) async throws {
        try await dbStore.write { context in
            if let book = try context.fetch(FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == index.bookID })).first {
                book.chapterIndexContentVersion = index.contentVersion
            }
            var descriptor = FetchDescriptor<ChapterIndexEntity>(predicate: #Predicate { $0.bookID == index.bookID && $0.contentVersion == index.contentVersion })
            descriptor.fetchLimit = 1
            let entity: ChapterIndexEntity
            if let existing = try context.fetch(descriptor).first {
                entity = existing
            } else {
                entity = ChapterIndexEntity(id: index.id, bookID: index.bookID, contentVersion: index.contentVersion, statusRawValue: index.status.rawValue, modelIdentifier: index.modelIdentifier, modelVersion: index.modelVersion, completedCount: index.progress.completed, totalCount: index.progress.total, errorMessage: index.errorMessage, createdAt: index.createdAt, updatedAt: index.updatedAt)
                context.insert(entity)
            }
            entity.statusRawValue = index.status.rawValue; entity.modelIdentifier = index.modelIdentifier; entity.modelVersion = index.modelVersion
            entity.completedCount = index.progress.completed; entity.totalCount = index.progress.total; entity.errorMessage = index.errorMessage; entity.updatedAt = index.updatedAt
            let indexID = entity.id
            try Self.deleteAll(context, of: ChapterSummaryEntity.self, matching: #Predicate { $0.indexID == indexID })
            for chapter in index.chapters {
                context.insert(ChapterSummaryEntity(id: UUID(), indexID: entity.id, chapterID: chapter.id, name: chapter.name, summary: chapter.summary, sourcePosition: chapter.sourcePosition, createdAt: index.createdAt, updatedAt: index.updatedAt))
            }
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
