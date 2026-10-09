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
    public nonisolated static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: SyncMetadataRow.self, SyncCursorStateRow.self, SyncRecoveryStateRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }

    public nonisolated static func makeStore(inMemory: Bool = false) async throws -> SwiftDataSyncMetadataStore {
        try await createStore(inMemory: inMemory, onContextCreation: nil)
    }

    #if DEBUG
    nonisolated static func makeStore(
        inMemory: Bool, onContextCreation: @escaping @Sendable (Bool) -> Void
    ) async throws -> SwiftDataSyncMetadataStore {
        try await createStore(inMemory: inMemory, onContextCreation: onContextCreation)
    }
    #endif

    private nonisolated static func contextWasCreatedOnMainThread() -> Bool {
        Thread.isMainThread
    }

    private nonisolated static func createStore(
        inMemory: Bool, onContextCreation: (@Sendable (Bool) -> Void)?
    ) async throws -> SwiftDataSyncMetadataStore {
        try await Task.detached {
            let container = try makeContainer(inMemory: inMemory)
            let store = SwiftDataSyncMetadataStore(modelContainer: container)
            onContextCreation?(contextWasCreatedOnMainThread())
            await store.configureExplicitSaves()
            return store
        }.value
    }
}

/// SwiftData-backed implementation of `SyncMetadataStore`.
@ModelActor
public actor SwiftDataSyncMetadataStore: SyncMetadataStore {
    private let bookIdentityGate = BookIdentityMutationGate()

    /// Construct the retained context off MainActor even when the caller is UI-owned.
    public nonisolated static func make(container: ModelContainer) async -> SwiftDataSyncMetadataStore {
        await Task.detached {
            let store = SwiftDataSyncMetadataStore(modelContainer: container)
            await store.configureExplicitSaves()
            return store
        }.value
    }

    fileprivate func configureExplicitSaves() { modelContext.autosaveEnabled = false }

    #if DEBUG
    private var nextSaveFailureForTesting: (any Error)?
    func failNextSaveForTesting(_ error: any Error) { nextSaveFailureForTesting = error }
    #endif

    /// Each synchronous mutation commits or rolls back before actor reentrancy.
    private func mutate<T>(_ body: (ModelContext) throws -> T) throws -> T {
        do {
            let result = try body(modelContext)
            if modelContext.hasChanges {
                #if DEBUG
                if let error = nextSaveFailureForTesting {
                    nextSaveFailureForTesting = nil
                    throw error
                }
                #endif
                try modelContext.save()
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func protectPositionPublication(_ id: UUID) async { await bookIdentityGate.protectPosition(id) }
    public func releasePositionPublication(_ id: UUID) async { await bookIdentityGate.releasePosition(id) }
    public func hasProtectedPositionPublication(_ id: UUID) async -> Bool { await bookIdentityGate.positionIsProtected(id) }

    public func retireRejectedPosition(entityId: UUID, expectedDirtyAt: Date?, expectedOperationId: UUID, previousLastSyncedAt: Date?) async throws -> Bool {
        let id = entityId.uuidString
        return try mutate { context in
            guard let row = try Self.fetchRow(entityId: id, kind: SyncEntityKind.position.rawValue, in: context),
                  row.dirty, row.dirtyAt == expectedDirtyAt, row.operationId == expectedOperationId else { return false }
            row.dirty = false; row.dirtyAt = nil; row.operationId = nil
            row.lastSyncedAt = previousLastSyncedAt
            return true
        }
    }

    public func withLiveBookIdentity<T: Sendable>(_ id: UUID, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await bookIdentityGate.withBook(id) {
            guard try await !self.isTombstone(entityId: id, kind: .book) else { throw SyncMetadataError.bookIdentityClosed(id) }
            return try await operation()
        }
    }

    public func applyLocalBookTombstone(_ id: UUID, mutation: @escaping @Sendable () async throws -> Void) async throws {
        try await bookIdentityGate.withBook(id) {
            if try await !self.isTombstone(entityId: id, kind: .book) {
                try await self.markTombstoneUngated(entityId: id, kind: .book)
            }
            do { try await mutation() }
            catch {
                Log.error("sync.book.delete.canonical_failed", error: error)
                throw SyncMetadataError.savedBookTombstone(id)
            }
        }
    }

    public func applyBookTombstoneIfUnchanged(_ id: UUID, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?, mutation: @escaping @Sendable () async throws -> Void) async throws -> Bool {
        try await bookIdentityGate.withBook(id) {
            guard try await self.dirtyAt(entityId: id, kind: .book) == expectedDirtyAt else { return false }
            try await mutation()
            return try await self.acknowledgeTombstoneIfUnchangedUngated(entityId: id, kind: .book, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
        }
    }

    public func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {
        _ = try await markDirtyIfAdmitted(entityId: entityId, kind: kind)
    }

    public func markUntrackedBookDirtyIfAdmitted(_ entityId: UUID) async throws -> Bool {
        let id = entityId.uuidString
        let type = SyncEntityKind.book.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        // The final candidate check and new operation share one persistence mutation.
        // Ordinary import dirty marks need not enter the book identity gate.
        return try mutate { context in
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                guard !row.dirty, !row.tombstone, row.lastSyncedAt == nil, row.dirtyAt == nil else { return false }
                row.dirty = true
                row.dirtyAt = Date()
                row.operationId = UUID()
            } else {
                context.insert(SyncMetadataRow(entityId: key, entityType: type,
                    dirtyAt: Date(), operationId: UUID(), dirty: true))
            }
            return true
        }
    }

    public func markDirtyIfAdmitted(entityId: UUID, kind: SyncEntityKind) async throws -> SyncDirtyMarkDisposition {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        return try mutate { context in
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                if kind == .book, row.tombstone { return row.dirty ? .pending : .ignoredClosedBook }
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
            return .pending
        }
    }

    public func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try mutate { context in
            if let row = try Self.fetchRow(entityId: id, kind: type, in: context) {
                guard kind != .book || !row.tombstone else { return }
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
        return try mutate { context in
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context) else {
                guard expectedDirtyAt == nil else { return false }
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    lastSyncedAt: lastSyncedAt,
                    dirty: false,
                    tombstone: false
                ))
                return true
            }
            guard (kind != .book || !row.tombstone), row.dirtyAt == expectedDirtyAt else { return false }
            row.entityType = type
            row.remoteEtag = remoteEtag
            row.lastSyncedAt = lastSyncedAt
            row.dirty = false
            row.dirtyAt = nil
            row.operationId = nil
            row.tombstone = false
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
        return try mutate { context in
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context),
                  (kind != .book || !row.tombstone),
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
            return true
        }
    }

    public func acknowledgeTombstoneIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
        if kind == .book {
            return try await bookIdentityGate.withBook(entityId) { try await self.acknowledgeTombstoneIfUnchangedUngated(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag) }
        }
        return try await acknowledgeTombstoneIfUnchangedUngated(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
    }

    private func acknowledgeTombstoneIfUnchangedUngated(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        return try mutate { context in
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context) else {
                guard expectedDirtyAt == nil else { return false }
                context.insert(SyncMetadataRow(
                    entityId: key,
                    entityType: type,
                    lastSyncedAt: lastSyncedAt,
                    dirty: false,
                    tombstone: true
                ))
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
            return true
        }
    }

    public func acknowledgeTombstoneIfCurrent(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, expectedOperationId: UUID, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
        if kind == .book {
            return try await bookIdentityGate.withBook(entityId) { try await self.acknowledgeTombstoneIfCurrentUngated(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, expectedOperationId: expectedOperationId, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag) }
        }
        return try await acknowledgeTombstoneIfCurrentUngated(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, expectedOperationId: expectedOperationId, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
    }

    private func acknowledgeTombstoneIfCurrentUngated(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        expectedOperationId: UUID,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try mutate { context in
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
            return true
        }
    }

    public func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try mutate { context in
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
        }
    }

    public func remoteSeenAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try Self.fetchRow(entityId: id, kind: type, in: modelContext)?.remoteSeenAt
    }

    public func allDirty() async throws -> [SyncPendingItem] {
        let descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.dirty },
            sortBy: [SortDescriptor(\SyncMetadataRow.entityId)]
        )
        return try modelContext.fetch(descriptor).compactMap(Self.decodePending)
    }

    public func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] {
        let type = kind.rawValue
        var descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.dirty && $0.entityType == type },
            sortBy: [SortDescriptor(\SyncMetadataRow.entityId)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap(Self.decodePending)
    }

    public func pendingCount() async throws -> Int {
        let descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { $0.dirty }
        )
        return try modelContext.fetchCount(descriptor)
    }

    public func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? {
        let type = kind.rawValue
        var descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { !$0.dirty && $0.entityType == type && $0.lastSyncedAt != nil },
            sortBy: [SortDescriptor(\SyncMetadataRow.lastSyncedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.lastSyncedAt
    }

    public func globalLastSyncedAt() async throws -> Date? {
        var descriptor = FetchDescriptor<SyncMetadataRow>(
            predicate: #Predicate { !$0.dirty && $0.lastSyncedAt != nil },
            sortBy: [SortDescriptor(\SyncMetadataRow.lastSyncedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.lastSyncedAt
    }

    public func forget(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try mutate { context in
            let descriptor = FetchDescriptor<SyncMetadataRow>(
                predicate: #Predicate { $0.entityId == key && $0.entityType == type }
            )
            for row in try context.fetch(descriptor) {
                if kind != .book || !row.tombstone { context.delete(row) }
            }
        }
    }

    /// Clears account-scoped sync cursors and dirty flags during sign-out so
    /// the next account cannot inherit the previous account's high-water mark.
    public func resetAll() async throws {
        try await bookIdentityGate.withExclusive {
            try await self.resetAllUngated()
            await self.bookIdentityGate.clearProtectedPositions()
        }
    }

    private func resetAllUngated() async throws {
        try mutate { context in
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
        }
    }

    public func markTombstone(entityId: UUID, kind: SyncEntityKind) async throws {
        if kind == .book {
            try await bookIdentityGate.withBook(entityId) { try await self.markTombstoneUngated(entityId: entityId, kind: kind) }
        } else { try await markTombstoneUngated(entityId: entityId, kind: kind) }
    }

    private func markTombstoneUngated(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let key = Self.storageId(entityId: id, kind: type)
        try mutate { context in
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
        }
    }

    public func isTombstone(entityId: UUID, kind: SyncEntityKind) async throws -> Bool {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try Self.fetchRow(entityId: id, kind: type, in: modelContext)?.tombstone ?? false
    }

    public func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try Self.fetchRow(entityId: id, kind: type, in: modelContext)?.dirtyAt
    }

    public func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try Self.fetchRow(entityId: id, kind: type, in: modelContext)?.operationId
    }

    public func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try mutate { context in
            guard let row = try Self.fetchRow(entityId: id, kind: type, in: context) else {
                throw SyncMetadataError.missingPendingOperation(entityId: entityId, kind: kind)
            }
            guard row.dirty else {
                throw SyncMetadataError.missingPendingOperation(entityId: entityId, kind: kind)
            }
            if let operationId = row.operationId { return operationId }
            let operationId = UUID()
            row.operationId = operationId
            return operationId
        }
    }

    public func lastSyncedAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
        let id = entityId.uuidString
        let type = kind.rawValue
        return try Self.fetchRow(entityId: id, kind: type, in: modelContext)?.lastSyncedAt
    }

    public func cursorState(for scope: SyncCursorScope) async throws -> SyncCursorState? {
        let rawScope = scope.rawValue
        let descriptor = FetchDescriptor<SyncCursorStateRow>(
            predicate: #Predicate { $0.scope == rawScope }
        )
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        return SyncCursorState(scope: scope, cursor: row.cursor, accountGeneration: row.accountGeneration)
    }

    public func saveCursorState(_ state: SyncCursorState) async throws {
        let rawScope = state.scope.rawValue
        try mutate { context in
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope }
            )
            if let row = try context.fetch(descriptor).first {
                row.cursor = state.cursor
                row.accountGeneration = state.accountGeneration
            } else {
                context.insert(SyncCursorStateRow(scope: rawScope, cursor: state.cursor, accountGeneration: state.accountGeneration))
            }
        }
    }

    public func clearCursorState(for scope: SyncCursorScope) async throws {
        let rawScope = scope.rawValue
        try mutate { context in
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
        }
    }

    public func clearCursorState(for scope: SyncCursorScope, accountGeneration: Int) async throws {
        let rawScope = scope.rawValue
        try mutate { context in
            let descriptor = FetchDescriptor<SyncCursorStateRow>(
                predicate: #Predicate { $0.scope == rawScope && $0.accountGeneration == accountGeneration }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
        }
    }

    public func recoveryState() async throws -> SyncRecoveryState? {
        let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
            predicate: #Predicate { $0.id == "account" }
        )
        guard let row = try modelContext.fetch(descriptor).first,
              let reason = SyncRecoveryReason(rawValue: row.reason) else {
            return nil
        }
        return SyncRecoveryState(reason: reason, accountGeneration: row.accountGeneration)
    }

    public func saveRecoveryState(_ state: SyncRecoveryState) async throws {
        try mutate { context in
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
        }
    }

    public func clearRecoveryState() async throws {
        try mutate { context in
            let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
                predicate: #Predicate { $0.id == "account" }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
        }
    }

    public func clearRecoveryState(accountGeneration: Int) async throws {
        try mutate { context in
            let descriptor = FetchDescriptor<SyncRecoveryStateRow>(
                predicate: #Predicate { $0.id == "account" && $0.accountGeneration == accountGeneration }
            )
            for row in try context.fetch(descriptor) {
                context.delete(row)
            }
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
