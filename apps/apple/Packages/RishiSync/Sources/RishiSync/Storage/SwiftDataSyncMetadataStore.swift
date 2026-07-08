import Foundation
import SwiftData
import RishiCore

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
        try await MainActor.run {
            let context = ModelContext(container)
            if let row = try Self.fetchRow(entityId: id, in: context) {
                row.entityType = type
                row.dirty = true
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: id,
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
        try await MainActor.run {
            let context = ModelContext(container)
            if let row = try Self.fetchRow(entityId: id, in: context) {
                row.entityType = type
                row.remoteEtag = remoteEtag
                row.lastSyncedAt = lastSyncedAt
                row.dirty = false
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: id,
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
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { $0.entityId == id && $0.entityType == type }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    private static func fetchRow(entityId: String, in context: ModelContext) throws -> SyncMetadataRow? {
        let descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.entityId == entityId }
        )
        return try context.fetch(descriptor).first
    }

    private static func decodePending(_ row: SyncMetadataRow) -> SyncPendingItem? {
        guard
            let id = UUID(uuidString: row.entityId),
            let kind = SyncEntityKind(rawValue: row.entityType)
        else { return nil }
        return SyncPendingItem(entityId: id, kind: kind)
    }

}
