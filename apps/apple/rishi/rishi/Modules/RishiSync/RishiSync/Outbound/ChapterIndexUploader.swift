import Foundation

/// Pushes the complete chapter index for each dirty book as one atomic sync
/// envelope. The queue entity id is the book id so the content-version lookup
/// remains compatible with the existing BookStore surface.
public final class ChapterIndexUploader: Sendable {
    private let workerClient: WorkerClient
    private let bookStore: any BookStore
    private let persistence: any ChapterIndexPersistence
    private let metadataStore: any SyncMetadataStore

    public init(
        workerClient: WorkerClient,
        bookStore: any BookStore,
        persistence: any ChapterIndexPersistence,
        metadataStore: any SyncMetadataStore
    ) {
        self.workerClient = workerClient
        self.bookStore = bookStore
        self.persistence = persistence
        self.metadataStore = metadataStore
    }

    @discardableResult
    public func pushPending(items: [SyncQueueItem]) async throws -> Int {
        var changes: [SyncChange] = []
        var resolved: [UUID] = []
        for item in items where item.kind == .chapterIndex {
            guard let book = try await bookStore.book(item.entityId) else { continue }
            guard let contentVersion = book.chapterIndexContentVersion,
                  let index = try await persistence.chapterIndex(bookID: book.id, contentVersion: contentVersion) else {
                // Keep the dirty marker when local metadata is incomplete. A
                // later retry can observe the persisted index after SwiftData
                // finishes updating the book aggregate.
                continue
            }
            changes.append(SyncChange(
                kind: SyncEntityKind.chapterIndex.rawValue,
                id: book.id,
                payload: try SyncPayloadCodec.encodeChapterIndex(index),
                updatedAt: try await metadataStore.dirtyAt(entityId: item.entityId, kind: .chapterIndex) ?? index.updatedAt,
                deleted: false
            ))
            resolved.append(item.entityId)
        }
        guard !changes.isEmpty else { return 0 }
        let response = try await workerClient.send(SyncPushEndpoint(body: .init(changes: changes)))
        for id in resolved {
            try await metadataStore.markClean(entityId: id, kind: .chapterIndex, lastSyncedAt: response.acceptedAt, remoteEtag: nil)
        }
        return resolved.count
    }
}
