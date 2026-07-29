import Foundation
import SwiftData


@Model
final class SyncMetadataRow {
    @Attribute(.unique) var entityId: String
    var entityType: String
    var remoteEtag: String?
    var lastSyncedAt: Date?
    var dirty: Bool

    init(
        entityId: String,
        entityType: String,
        remoteEtag: String? = nil,
        lastSyncedAt: Date? = nil,
        dirty: Bool = false
    ) {
        self.entityId = entityId
        self.entityType = entityType
        self.remoteEtag = remoteEtag
        self.lastSyncedAt = lastSyncedAt
        self.dirty = dirty
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
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: key,
                        entityType: type,
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
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: key,
                        entityType: type,
                        remoteEtag: remoteEtag,
                        lastSyncedAt: lastSyncedAt,
                        dirty: false
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

    private static func storageId(entityId: String, kind: String) -> String {
        "(kind):(entityId)"
    }

    private static func fetchRow(entityId: String, kind: String, in context: ModelContext) throws -> SyncMetadataRow? {
        let namespaced = storageId(entityId: entityId, kind: kind)
        let descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.entityId == namespaced }
        )
        return try context.fetch(descriptor).first
    }

    private static func decodePending(_ row: SyncMetadataRow) -> SyncPendingItem? {
        let rawId = row.entityId.hasPrefix("(row.entityType):")
            ? String(row.entityId.dropFirst(row.entityType.count + 1))
            : row.entityId
        guard let id = UUID(uuidString: rawId), let kind = SyncEntityKind(rawValue: row.entityType) else { return nil }
        return SyncPendingItem(entityId: id, kind: kind)
    }

}
