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
        currentUserID: @escaping @Sendable () async -> UserID?
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
