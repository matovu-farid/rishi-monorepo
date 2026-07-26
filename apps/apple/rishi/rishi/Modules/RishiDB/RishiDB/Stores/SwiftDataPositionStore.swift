import Foundation
import SwiftData



/// SwiftData-backed `PositionStore`.
public final class SwiftDataPositionStore: PositionStore, Sendable {

    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func position(for bookId: BookID) async throws -> Position? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Positions.table,
            "operation": "position_for_book",
        ])
        do {
            return try await dbStore.read { context -> Position? in
                var descriptor = FetchDescriptor<PositionEntity>(
                    predicate: #Predicate { $0.bookId == bookId },
                    sortBy: [SortDescriptor(\PositionEntity.updatedAt, order: .reverse)]
                )
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.positionValue
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("position(for:) failed: \(error)")
        }
    }

    public func upsert(_ position: Position) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Positions.table,
            "operation": "upsert",
        ])
        do {
            try await dbStore.write { context in
                var descriptor = FetchDescriptor<PositionEntity>(predicate: #Predicate { $0.id == position.id })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.update(from: position)
                } else {
                    context.insert(
                        PositionEntity(
                            id: position.id,
                            bookId: position.bookId,
                            locator: position.locator,
                            percentComplete: position.percentComplete,
                            updatedAt: position.updatedAt
                        )
                    )
                }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(position:) failed: \(error)")
        }
    }

    public func delete(_ id: PositionID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Positions.table,
            "operation": "delete",
        ])
        do {
            try await dbStore.write { context in
                try Self.deleteAll(context, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(position:) failed: \(error)")
        }
    }

    private static func deleteAll(_ context: ModelContext, matching predicate: Predicate<PositionEntity>) throws {
        let descriptor = FetchDescriptor<PositionEntity>(predicate: predicate)
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }
}
