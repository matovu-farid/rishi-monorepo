import Foundation

/// Classifies durable dirty records before queue claims so source-readable
/// imports and their children remain queued until managed bytes are verified
/// and the parent book has been accepted by the server.
public struct BookReadinessPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case eligible
        case discard
        case blocked
        case dependency(SyncQueueItem)
    }

    private let bookStore: any BookStore
    private let positionStore: any PositionStore
    private let highlightStore: any HighlightStore
    private let bookmarkStore: any BookmarkStore
    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore
    private let chapterIndexes: (any ChapterIndexPersistence)?
    private let metadataStore: any SyncMetadataStore
    private let sourceResolver: any BookSourceResolving
    private let currentUserID: @Sendable () async -> UserID?
    private let revalidateManagedSource: @Sendable (Book, ManagedBookSource) async throws -> Bool

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        bookmarkStore: any BookmarkStore,
        conversationStore: any ConversationStore,
        messageStore: any MessageStore,
        chapterIndexes: (any ChapterIndexPersistence)?,
        metadataStore: any SyncMetadataStore,
        sourceResolver: any BookSourceResolving,
        currentUserID: @escaping @Sendable () async -> UserID?,
        revalidateManagedSource: @escaping @Sendable (Book, ManagedBookSource) async throws -> Bool = { _, _ in false }
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.chapterIndexes = chapterIndexes
        self.metadataStore = metadataStore
        self.sourceResolver = sourceResolver
        self.currentUserID = currentUserID
        self.revalidateManagedSource = revalidateManagedSource
    }

    /// Recover the registration/dirty-mark crash window after inbound tombstones have applied.
    /// Already pending operations and clean legacy books retain their existing metadata.
    public func reconcileUntrackedBooks(
        expectedUserID: UserID,
        isCurrentAccount: @escaping @Sendable () async -> Bool
    ) async throws -> [SyncQueueItem] {
        guard await isCurrentAccount(), await currentUserID() == expectedUserID else { return [] }
        let dirtyBookIDs = Set(try await metadataStore.allDirty().filter { $0.kind == .book }.map(\.entityId))
        var recovered: [SyncQueueItem] = []
        for book in try await bookStore.books(for: expectedUserID) {
            guard await isCurrentAccount(), await currentUserID() == expectedUserID else { break }
            guard book.userId == expectedUserID, !dirtyBookIDs.contains(book.id),
                  try await isUntracked(book.id) else { continue }
            // This can coordinate/hash/backfill bytes. Never put it in withLiveBookIdentity.
            guard let source = try await sourceResolver.managedSource(for: book) else { continue }
            do {
                let admitted = try await metadataStore.withLiveBookIdentity(book.id) { [self] in
                    guard await isCurrentAccount(), await currentUserID() == expectedUserID,
                          let canonical = try await bookStore.book(book.id),
                          canonical.userId == expectedUserID, canonical.fileURL == book.fileURL,
                          canonical.formatType == book.formatType, try await isUntracked(book.id),
                          try await revalidateManagedSource(canonical, source),
                          await isCurrentAccount(), await currentUserID() == expectedUserID,
                          try await isUntracked(book.id),
                          !(try await metadataStore.allDirty()).contains(where: { $0.kind == .book && $0.entityId == book.id })
                    else { return false }
                    return try await metadataStore.markUntrackedBookDirtyIfAdmitted(book.id)
                }
                if admitted { recovered.append(SyncQueueItem(entityId: book.id, kind: .book)) }
            } catch SyncMetadataError.bookIdentityClosed {
                // A deletion that committed while source resolution was suspended wins.
                continue
            }
        }
        return recovered
    }

    private func isUntracked(_ id: BookID) async throws -> Bool {
        guard try await !metadataStore.isTombstone(entityId: id, kind: .book),
              try await metadataStore.dirtyAt(entityId: id, kind: .book) == nil,
              try await metadataStore.lastSyncedAt(entityId: id, kind: .book) == nil else { return false }
        return true
    }

    public func classify(_ item: SyncQueueItem) async throws -> Decision {
        let ownerID = await currentUserID()
        switch item.kind {
        case .book:
            if try await metadataStore.isTombstone(entityId: item.entityId, kind: .book) {
                return try await metadataStore.dirtyAt(entityId: item.entityId, kind: .book) == nil ? .discard : .eligible
            }
            guard let book = try await bookStore.book(item.entityId), book.userId == ownerID else { return .blocked }
            guard try await sourceResolver.managedSource(for: book) != nil else { return .blocked }
            return .eligible
        case .position:
            guard let position = try await positionStore.position(for: item.entityId) else { return .blocked }
            return try await childDecision(bookID: position.bookId)
        case .highlight:
            guard let highlight = try await highlightStore.highlight(item.entityId) else {
                return try await metadataStore.isTombstone(entityId: item.entityId, kind: .highlight) ? .eligible : .blocked
            }
            return try await childDecision(bookID: highlight.bookId)
        case .bookmark:
            guard let bookmark = try await bookmarkStore.bookmark(item.entityId) else {
                return try await metadataStore.isTombstone(entityId: item.entityId, kind: .bookmark) ? .eligible : .blocked
            }
            return try await childDecision(bookID: bookmark.bookId)
        case .chapterIndex:
            guard let book = try await bookStore.book(item.entityId),
                  let version = book.chapterIndexContentVersion,
                  let indexes = chapterIndexes,
                  try await indexes.chapterIndex(bookID: book.id, contentVersion: version) != nil else { return .blocked }
            return try await childDecision(bookID: book.id)
        case .conversation:
            guard let conversation = try await conversationStore.conversation(item.entityId) else {
                return try await metadataStore.isTombstone(entityId: item.entityId, kind: .conversation) ? .eligible : .blocked
            }
            guard conversation.userId == ownerID else { return .blocked }
            if let bookID = conversation.bookId { return try await childDecision(bookID: bookID) }
            return .eligible
        case .message:
            guard let message = try await messageStore.message(item.entityId) else {
                return try await metadataStore.isTombstone(entityId: item.entityId, kind: .message) ? .eligible : .blocked
            }
            guard let conversation = try await conversationStore.conversation(message.conversationId),
                  conversation.userId == ownerID else { return .blocked }
            if let bookID = conversation.bookId {
                let bookDecision = try await childDecision(bookID: bookID)
                guard bookDecision == .eligible else { return bookDecision }
            }
            let acceptedAt = try await metadataStore.lastSyncedAt(entityId: conversation.id, kind: .conversation)
            let pending = try await metadataStore.dirtyAt(entityId: conversation.id, kind: .conversation)
            if acceptedAt != nil && pending == nil { return .eligible }
            return .dependency(SyncQueueItem(entityId: conversation.id, kind: .conversation))
        }
    }

    private func childDecision(bookID: BookID) async throws -> Decision {
        let ownerID = await currentUserID()
        guard let book = try await bookStore.book(bookID), book.userId == ownerID else { return .blocked }
        guard let source = try await sourceResolver.managedSource(for: book) else {
            return .dependency(SyncQueueItem(entityId: bookID, kind: .book))
        }
        guard let acceptance = source.fingerprint.serverAcceptance,
              acceptance.sha256.caseInsensitiveCompare(source.fingerprint.sha256) == .orderedSame else {
            return .dependency(SyncQueueItem(entityId: bookID, kind: .book))
        }
        return .eligible
    }
}
