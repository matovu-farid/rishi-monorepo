import Foundation
import SwiftData


@Model
final class SyncMetadataRow {
    @Attribute(.unique) var entityId: String
    var entityType: String
    var remoteEtag: String?
    var lastSyncedAt: Date?
    var dirtyAt: Date?
    var dirty: Bool
    // A model default is required for SwiftData's lightweight migration of
    // existing stores; the initializer default alone does not populate the
    // new column for rows already on disk.
    var tombstone: Bool = false

    init(
        entityId: String,
        entityType: String,
        remoteEtag: String? = nil,
        lastSyncedAt: Date? = nil,
        dirtyAt: Date? = nil,
        dirty: Bool = false,
        tombstone: Bool = false
    ) {
        self.entityId = entityId
        self.entityType = entityType
        self.remoteEtag = remoteEtag
        self.lastSyncedAt = lastSyncedAt
        self.dirtyAt = dirtyAt
        self.dirty = dirty
        self.tombstone = tombstone
    }
}

public enum SyncMetadataStoreBootstrap {
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: SyncMetadataRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }

    public static func makeStore(inMemory: Bool = false) throws -> SwiftDataSyncMetadataStore {
        SwiftDataSyncMetadataStore(container: try makeContainer(inMemory: inMemory))
    }
}

/// SwiftData-backed implementation of `SyncMetadataStore`.
public actor SwiftDataSyncMetadataStore: SyncMetadataStore {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try await MainActor.run {
            let context = ModelContext(container)
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                row.entityType = type
                row.dirty = true
                row.dirtyAt = Date()
                row.tombstone = false
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: key,
                        entityType: type,
                        dirtyAt: Date(),
                        dirty: true
                    )
                )
            }
            try context.save()
        }
    }

    public func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try await MainActor.run {
            let context = ModelContext(container)
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                row.entityType = type
                row.remoteEtag = remoteEtag
                row.lastSyncedAt = lastSyncedAt
                row.dirty = false
                row.dirtyAt = nil
                row.tombstone = false
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: key,
                        entityType: type,
                        remoteEtag: remoteEtag,
                        lastSyncedAt: lastSyncedAt,
                        dirty: false,
                        tombstone: false
                    )
                )
            }
            try context.save()
        }
    }

    public func allDirty() async throws -> [SyncPendingItem] {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { $0.dirty },
                sortBy: [SortDescriptor(\SyncMetadataRow.entityId)]
            )
            return try context.fetch(descriptor).compactMap(Self.decodePending)
        }
    }

    public func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] {
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { $0.dirty && $0.entityType == type },
                sortBy: [SortDescriptor(\SyncMetadataRow.entityId)]
            )
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).compactMap(Self.decodePending)
        }
    }

    public func pendingCount() async throws -> Int {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { $0.dirty }
            )
            return try context.fetch(descriptor).count
        }
    }

    public func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? {
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { !$0.dirty && $0.entityType == type }
            )
            return try context.fetch(descriptor).compactMap(\.lastSyncedAt).max()
        }
    }

    public func globalLastSyncedAt() async throws -> Date? {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { !$0.dirty }
            )
            return try context.fetch(descriptor).compactMap(\.lastSyncedAt).max()
        }
    }

    public func forget(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { $0.entityId == key && $0.entityType == type }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    /// Clears account-scoped sync cursors and dirty flags during sign-out so
    /// the next account cannot inherit the previous account's high-water mark.
    public func resetAll() async throws {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>()
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    public func markTombstone(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try await MainActor.run {
            let context = ModelContext(container)
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                row.entityType = type
                row.dirty = true
                row.dirtyAt = Date()
                row.tombstone = true
            } else {
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    dirtyAt: Date(),
                    dirty: true,
                    tombstone: true
                ))
            }
            try context.save()
        }
    }

    public func isTombstone(entityId: UUID, kind: SyncEntityKind) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            return try Self.fetchRow(entityId: id, kind: type, in: context)?.tombstone ?? false
        }
    }

    public func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            return try Self.fetchRow(entityId: id, kind: type, in: context)?.dirtyAt
        }
    }

    public func lastSyncedAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            return try Self.fetchRow(entityId: id, kind: type, in: context)?.lastSyncedAt
        }
    }

    private static func storageId(entityId: String, kind: String) -> String {
        "\(kind):\(entityId)"
    }

    private static func fetchRow(entityId: String, kind: String, in context: ModelContext) throws -> SyncMetadataRow? {
        let namespaced = storageId(entityId: entityId, kind: kind)
        let descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.entityId == namespaced }
        )
        return try context.fetch(descriptor).first
    }

    private static func decodePending(_ row: SyncMetadataRow) -> SyncPendingItem? {
        let prefix = "\(row.entityType):"
        // Accept legacy raw UUID rows while new writes use a kind-prefixed
        // key, so existing installations retain their pending queue.
        let rawId = row.entityId.hasPrefix(prefix)
            ? String(row.entityId.dropFirst(prefix.count))
            : row.entityId
        guard let id = UUID(uuidString: rawId), let kind = SyncEntityKind(rawValue: row.entityType) else { return nil }
        return SyncPendingItem(entityId: id, kind: kind)
    }

}
