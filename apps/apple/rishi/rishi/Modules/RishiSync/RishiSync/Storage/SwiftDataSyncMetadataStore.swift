import Foundation
import SwiftData


@Model
final class SyncMetadataRow {
    @Attribute(.unique) var entityId: String
    var entityType: String
    var remoteEtag: String?
    var lastSyncedAt: Date?
    var remoteSeenAt: Date?
    var dirtyAt: Date?
    var operationId: UUID?
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
        remoteSeenAt: Date? = nil,
        dirtyAt: Date? = nil,
        operationId: UUID? = nil,
        dirty: Bool = false,
        tombstone: Bool = false
    ) {
        self.entityId = entityId
        self.entityType = entityType
        self.remoteEtag = remoteEtag
        self.lastSyncedAt = lastSyncedAt
        self.remoteSeenAt = remoteSeenAt
        self.dirtyAt = dirtyAt
        self.operationId = operationId
        self.dirty = dirty
        self.tombstone = tombstone
    }
}

public enum SyncMetadataStoreBootstrap {
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: SyncMetadataRow.self, SyncCursorStateRow.self, SyncRecoveryStateRow.self,
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
                // markDirty is called by a local write path, not by queue
                // hydration. A new write therefore needs a new operation ID;
                // retries never call markDirty and retain the old ID.
                row.operationId = UUID()
                row.tombstone = false
            } else {
                context.insert(
                    SyncMetadataRow(
                        entityId: key,
                        entityType: type,
                        dirtyAt: Date(),
                        operationId: UUID(),
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
                row.operationId = nil
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

    public func markCleanIfUnchanged(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        return try await MainActor.run {
            let context = ModelContext(container)
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context) else {
                guard expectedDirtyAt == nil else { return false }
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    lastSyncedAt: lastSyncedAt,
                    dirty: false,
                    tombstone: false
                ))
                try context.save()
                return true
            }
            guard row.dirtyAt == expectedDirtyAt else { return false }
            row.entityType = type
            row.remoteEtag = remoteEtag
            row.lastSyncedAt = lastSyncedAt
            row.dirty = false
            row.dirtyAt = nil
            row.operationId = nil
            row.tombstone = false
            try context.save()
            return true
        }
    }

    public func markCleanIfCurrent(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        expectedOperationId: UUID,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context),
                  row.dirty,
                  row.dirtyAt == expectedDirtyAt,
                  row.operationId == expectedOperationId else { return false }
            row.entityType = type
            row.remoteEtag = remoteEtag
            row.lastSyncedAt = lastSyncedAt
            row.dirty = false
            row.dirtyAt = nil
            row.operationId = nil
            row.tombstone = false
            try context.save()
            return true
        }
    }

    public func acknowledgeTombstoneIfUnchanged(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        return try await MainActor.run {
            let context = ModelContext(container)
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context) else {
                guard expectedDirtyAt == nil else { return false }
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    lastSyncedAt: lastSyncedAt,
                    dirty: false,
                    tombstone: true
                ))
                try context.save()
                return true
            }
            guard row.dirtyAt == expectedDirtyAt else { return false }
            row.entityType = type
            row.remoteEtag = remoteEtag
            row.lastSyncedAt = lastSyncedAt
            row.dirty = false
            row.dirtyAt = nil
            row.operationId = nil
            row.tombstone = true
            try context.save()
            return true
        }
    }

    public func acknowledgeTombstoneIfCurrent(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        expectedOperationId: UUID,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context),
                  row.dirty,
                  row.tombstone,
                  row.dirtyAt == expectedDirtyAt,
                  row.operationId == expectedOperationId else { return false }
            row.entityType = type
            row.remoteEtag = remoteEtag
            row.lastSyncedAt = lastSyncedAt
            row.dirty = false
            row.dirtyAt = nil
            row.operationId = nil
            // Keep tombstone=true as the permanent closed-identity barrier.
            try context.save()
            return true
        }
    }

    public func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try await MainActor.run {
            let context = ModelContext(container)
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                if row.remoteSeenAt == nil || row.remoteSeenAt! < updatedAt {
                    row.remoteSeenAt = updatedAt
                }
            } else {
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    remoteSeenAt: updatedAt,
                    dirty: false,
                    tombstone: false
                ))
            }
            try context.save()
        }
    }

    public func remoteSeenAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            return try Self.fetchRow(entityId: id, kind: type, in: context)?.remoteSeenAt
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
            let metadataDescriptor = FetchDescriptor<SyncMetadataRow>()
            for row in try context.fetch(metadataDescriptor) {
                context.delete(row)
            }
            let cursorDescriptor = FetchDescriptor<SyncCursorStateRow>()
            for row in try context.fetch(cursorDescriptor) {
                context.delete(row)
            }
            let recoveryDescriptor = FetchDescriptor<SyncRecoveryStateRow>()
            for row in try context.fetch(recoveryDescriptor) {
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
                let alreadyPendingTombstone = row.dirty && row.tombstone
                row.entityType = type
                row.dirty = true
                // Repeated retry of the same tombstone must reuse its ID;
                // converting a live mutation into a delete must rotate it.
                if !alreadyPendingTombstone {
                    row.dirtyAt = Date()
                    row.operationId = UUID()
                }
                row.tombstone = true
            } else {
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    dirtyAt: Date(),
                    operationId: UUID(),
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

    public func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            return try Self.fetchRow(entityId: id, kind: type, in: context)?.operationId
        }
    }

    public func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context) else {
                throw SyncMetadataError.missingPendingOperation(entityId: entityId, kind: kind)
            }
            guard row.dirty else {
                throw SyncMetadataError.missingPendingOperation(entityId: entityId, kind: kind)
            }
            if let operationId = row.operationId { return operationId }
            let operationId = UUID()
            row.operationId = operationId
            try context.save()
            return operationId
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

    public func cursorState(for scope: SyncCursorScope) async throws -> SyncCursorState? {
        let rawScope = scope.rawValue
        return try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope }
            )
            guard let row = try context.fetch(descriptor).first else { return nil }
            return SyncCursorState(scope: scope, cursor: row.cursor, accountGeneration: row.accountGeneration)
        }
    }

    public func saveCursorState(_ state: SyncCursorState) async throws {
        let rawScope = state.scope.rawValue
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope }
            )
            if let row = try context.fetch(descriptor).first {
                row.cursor = state.cursor
                row.accountGeneration = state.accountGeneration
            } else {
                context.insert(SyncCursorStateRow(scope: rawScope, cursor: state.cursor, accountGeneration: state.accountGeneration))
            }
            try context.save()
        }
    }

    public func clearCursorState(for scope: SyncCursorScope) async throws {
        let rawScope = scope.rawValue
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    public func clearCursorState(for scope: SyncCursorScope, accountGeneration: Int) async throws {
        let rawScope = scope.rawValue
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope && $0.accountGeneration == accountGeneration }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    public func recoveryState() async throws -> SyncRecoveryState? {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
                predicate: #Predicate { $0.id == "account" }
            )
            guard let row = try context.fetch(descriptor).first,
                  let reason = SyncRecoveryReason(rawValue: row.reason) else {
                return nil
            }
            return SyncRecoveryState(reason: reason, accountGeneration: row.accountGeneration)
        }
    }

    public func saveRecoveryState(_ state: SyncRecoveryState) async throws {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
                predicate: #Predicate { $0.id == "account" }
            )
            if let row = try context.fetch(descriptor).first {
                row.reason = state.reason.rawValue
                row.accountGeneration = state.accountGeneration
            } else {
                context.insert(SyncRecoveryStateRow(
                    reason: state.reason.rawValue,
                    accountGeneration: state.accountGeneration
                ))
            }
            try context.save()
        }
    }

    public func clearRecoveryState() async throws {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
                predicate: #Predicate { $0.id == "account" }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    public func clearRecoveryState(accountGeneration: Int) async throws {
        try await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
                predicate: #Predicate { $0.id == "account" && $0.accountGeneration == accountGeneration }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
            try context.save()
        }
    }

    private static func storageId(entityId: String, kind: String) -> String {
        "\(kind):\(entityId)"
    }

    private static func fetchRow(entityId: String, kind: String, in context: ModelContext) throws -> SyncMetadataRow? {
        let namespaced = storageId(entityId: entityId, kind: kind)
        let namespacedDescriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.entityId == namespaced }
        )
        if let row = try context.fetch(namespacedDescriptor).first { return row }
        let legacyDescriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.entityId == entityId && $0.entityType == kind }
        )
        return try context.fetch(legacyDescriptor).first
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
