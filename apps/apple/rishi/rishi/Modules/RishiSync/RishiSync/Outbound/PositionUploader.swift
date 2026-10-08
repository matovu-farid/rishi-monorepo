import Foundation

/// Captures one immutable local operation under the shared book gate. Network
/// activity happens after release; acknowledgements compare the original revision.
public final class PositionUploader: Sendable {
    public enum UploadError: Error, Sendable { case encodingFailed(String) }

    public struct RejectedSnapshot: Sendable, Equatable {
        public let bookID: BookID
        public let position: Position
        public let dirtyAt: Date?
        public let operationID: UUID
        public let previousLastSyncedAt: Date?
    }
    public struct PushResult: Sendable, Equatable {
        public var acceptedCount = 0
        public var rejected: [RejectedSnapshot] = []
        public init() {}
    }
    private let workerClient: WorkerClient
    private let positionStore: any PositionStore
    private let metadataStore: any SyncMetadataStore
    private let currentUserId: @Sendable () async -> UserID?

    public init(workerClient: WorkerClient, positionStore: any PositionStore,
                bookStore: any BookStore, metadataStore: any SyncMetadataStore,
                currentUserId: @escaping @Sendable () async -> UserID? = { nil }) {
        self.workerClient = workerClient
        self.positionStore = positionStore
        self.metadataStore = metadataStore
        self.currentUserId = currentUserId
    }

    /// Caller holds the shared book gate through this check and retirement.
    func positionMatches(_ snapshot: RejectedSnapshot) async throws -> Bool {
        try await positionStore.position(for: snapshot.bookID) == snapshot.position
    }

    @discardableResult
    public func pushPending(items: [SyncQueueItem]) async throws -> Int {
        try await pushPendingWithOutcomes(items: items).acceptedCount
    }

    public func pushPendingWithOutcomes(items: [SyncQueueItem]) async throws -> PushResult {
        var result = PushResult()
        let owner = await currentUserId()
        var snapshots: [RejectedSnapshot] = []
        for item in items where item.kind == .position {
            try Task.checkCancellation()
            let snapshot = try await metadataStore.withLiveBookIdentity(item.entityId) { [self] () async throws -> RejectedSnapshot? in
                guard !(await metadataStore.hasProtectedPositionPublication(item.entityId)) else { return nil }
                let dirtyAt = try await metadataStore.dirtyAt(entityId: item.entityId, kind: .position)
                guard let position = try await positionStore.position(for: item.entityId) else {
                    _ = try await metadataStore.markCleanIfUnchanged(entityId: item.entityId, kind: .position, expectedDirtyAt: dirtyAt, lastSyncedAt: Date(), remoteEtag: nil)
                    return nil
                }
                let operationID = try await metadataStore.ensureOperationId(entityId: item.entityId, kind: .position)
                return RejectedSnapshot(bookID: item.entityId, position: position, dirtyAt: dirtyAt,
                                        operationID: operationID,
                                        previousLastSyncedAt: try await metadataStore.lastSyncedAt(entityId: item.entityId, kind: .position))
            }
            if let snapshot { snapshots.append(snapshot) }
        }
        guard !snapshots.isEmpty else { return result }
        let changes = try snapshots.map { snapshot in
            SyncChange(kind: SyncEntityKind.position.rawValue, id: snapshot.position.id,
                       operationId: snapshot.operationID.uuidString, payload: try SyncPayloadCodec.encodePosition(snapshot.position),
                       updatedAt: snapshot.position.updatedAt, deleted: false)
        }
        try Task.checkCancellation()
        guard await currentUserId() == owner else { throw CancellationError() }
        let response = try await workerClient.send(SyncPushEndpoint(body: .init(changes: changes)))
        try Task.checkCancellation()
        guard await currentUserId() == owner else { throw CancellationError() }
        for snapshot in snapshots {
            let matching = response.outcomes.filter { UUID(uuidString: $0.operationId) == snapshot.operationID }
            let accepted: Bool
            if response.outcomes.isEmpty {
                if response.accepted == false { result.rejected.append(snapshot); continue }
                accepted = true // older Workers return only accepted_at
            } else if matching.count == 1 {
                switch matching[0].status {
                case "applied", "duplicate": accepted = true
                case "rejected": result.rejected.append(snapshot); continue
                default: continue
                }
            } else { continue } // Missing or contradictory outcomes remain pending.
            guard accepted else { continue }
            let acknowledged = try await metadataStore.withLiveBookIdentity(snapshot.bookID) { [self] in
                try Task.checkCancellation()
                guard await currentUserId() == owner,
                      !(await metadataStore.hasProtectedPositionPublication(snapshot.bookID)),
                      try await positionStore.position(for: snapshot.bookID) == snapshot.position else { return false }
                return try await metadataStore.markCleanIfCurrent(entityId: snapshot.bookID, kind: .position,
                    expectedDirtyAt: snapshot.dirtyAt, expectedOperationId: snapshot.operationID,
                    lastSyncedAt: response.acceptedAt, remoteEtag: nil)
            }
            if acknowledged { result.acceptedCount += 1 }
        }
        return result
    }
}
