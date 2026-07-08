import Foundation
import SwiftData
import RishiCore
import RishiLogging

/// SwiftData-backed `HighlightStore`.
public final class SwiftDataHighlightStore: HighlightStore, Sendable {

    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func highlights(for bookId: BookID) async throws -> [Highlight] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "highlights_for_book",
        ])
        do {
            return try await dbStore.read { context in
                var descriptor = FetchDescriptor<HighlightEntity>(
                    predicate: #Predicate { $0.bookId == bookId },
                    sortBy: [SortDescriptor(\HighlightEntity.createdAt)]
                )
                descriptor.fetchLimit = nil
                return try context.fetch(descriptor).compactMap(\.highlightValue)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("highlights(for:) failed: \(error)")
        }
    }

    public func highlight(_ id: HighlightID) async throws -> Highlight? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "highlight_by_id",
        ])
        do {
            return try await dbStore.read { context -> Highlight? in
                var descriptor = FetchDescriptor<HighlightEntity>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.highlightValue
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("highlight(_:) failed: \(error)")
        }
    }

    public func upsert(_ highlight: Highlight) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "upsert",
        ])
        do {
            try await dbStore.write { context in
                var descriptor = FetchDescriptor<HighlightEntity>(predicate: #Predicate { $0.id == highlight.id })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.update(from: highlight)
                } else {
                    context.insert(
                        HighlightEntity(
                            id: highlight.id,
                            bookId: highlight.bookId,
                            locatorStart: highlight.locatorStart,
                            locatorEnd: highlight.locatorEnd,
                            colorRawValue: highlight.color.rawValue,
                            text: highlight.text,
                            note: highlight.note,
                            createdAt: highlight.createdAt
                        )
                    )
                }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(highlight:) failed: \(error)")
        }
    }

    public func delete(_ id: HighlightID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "delete",
        ])
        do {
            try await dbStore.write { context in
                try Self.deleteAll(context, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(highlight:) failed: \(error)")
        }
    }

    private static func deleteAll(_ context: ModelContext, matching predicate: Predicate<HighlightEntity>) throws {
        let descriptor = FetchDescriptor<HighlightEntity>(predicate: predicate)
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }
}
