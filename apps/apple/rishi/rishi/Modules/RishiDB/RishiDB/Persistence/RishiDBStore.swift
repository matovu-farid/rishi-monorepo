import Foundation
import SwiftData

public actor RishiDBStore {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func read<T>(_ operation: @Sendable (ModelContext) throws -> T) async rethrows -> T {
        try operation(context)
    }

    public func write<T>(_ operation: @Sendable (ModelContext) throws -> T) async throws -> T {
        do {
            let value = try operation(context)
            if context.hasChanges {
                try context.save()
            }
            return value
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    /// Permanently removes every account-scoped model from the local store.
    /// This is intentionally separate from sign-out: account deletion is the
    /// only flow allowed to erase the local library and conversation history.
    public func purgeAll() throws {
        try deleteAll(BookEntity.self)
        try deleteAll(PositionEntity.self)
        try deleteAll(HighlightEntity.self)
        try deleteAll(BookmarkEntity.self)
        try deleteAll(ConversationEntity.self)
        try deleteAll(MessageEntity.self)
        try deleteAll(UserEntity.self)
        try deleteAll(SyncMetadataEntity.self)
        try deleteAll(ChapterIndexEntity.self)
        try deleteAll(ChapterSummaryEntity.self)
        if context.hasChanges {
            try context.save()
        }
    }

    private func deleteAll<Model: PersistentModel>(_ type: Model.Type) throws {
        for model in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(model)
        }
    }
}
