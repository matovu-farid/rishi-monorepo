import Foundation


/// Outbound queue drain, extracted from `SyncEngine.runOnce` (plan 34-10 SRP).
///
/// Owns the per-kind bucketing + per-uploader dispatch + re-enqueue-on-error
/// that previously lived inline at `runOnce` step 2. Behavior is byte-identical:
///   - dequeue up to `limit` items, bucket by kind so a book-only drain can't
///     swallow position items as collateral;
///   - **Books** — one upload per item (no batch API); a missing local row
///     drops the dirty mark via `metadataStore.forget`; an error re-enqueues
///     that single item;
///   - **Positions / Highlights / Conversations / Messages** — batch
///     `pushPending`; an error re-enqueues every item in that bucket.
///
/// Error strings keep the exact "book.upload:" / "position.push:" / … prefixes
/// the engine emitted, so `Wave.errors` is unchanged.
struct OutboundDrainer: Sendable {

    struct DrainResult: Sendable, Equatable {
        var booksUploaded: Int = 0
        var positionsPushed: Int = 0
        var highlightsPushed: Int = 0
        var conversationsPushed: Int = 0
        var messagesPushed: Int = 0
        var bookmarksPushed: Int = 0
        var chapterIndexesPushed: Int = 0
        var errors: [String] = []
        init() {}
    }

    private let queue: SyncQueue
    private let bookStore: any BookStore
    private let metadataStore: any SyncMetadataStore
    private let bookUploader: BookUploader
    private let positionUploader: PositionUploader
    private let highlightUploader: HighlightUploader
    private let conversationUploader: ConversationUploader
    private let messageUploader: MessageUploader
    private let bookmarkUploader: BookmarkUploader
    private let chapterIndexUploader: ChapterIndexUploader
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider

    struct Dependencies {
        let queue: SyncQueue
        let bookStore: any BookStore
        let metadataStore: any SyncMetadataStore
        let bookUploader: BookUploader
        let positionUploader: PositionUploader
        let highlightUploader: HighlightUploader
        let conversationUploader: ConversationUploader
        let messageUploader: MessageUploader
        let bookmarkUploader: BookmarkUploader
        let chapterIndexUploader: ChapterIndexUploader
        let dataUseConsentProvider: any WorkerDataUseConsentProvider
    }

    init(dependencies: Dependencies) {
        self.queue = dependencies.queue
        self.bookStore = dependencies.bookStore
        self.metadataStore = dependencies.metadataStore
        self.bookUploader = dependencies.bookUploader
        self.positionUploader = dependencies.positionUploader
        self.highlightUploader = dependencies.highlightUploader
        self.conversationUploader = dependencies.conversationUploader
        self.messageUploader = dependencies.messageUploader
        self.bookmarkUploader = dependencies.bookmarkUploader
        self.chapterIndexUploader = dependencies.chapterIndexUploader
        self.dataUseConsentProvider = dependencies.dataUseConsentProvider
    }

    /// Drain up to `limit` queue items and push them by kind.
    func drain(limit: Int) async -> DrainResult {
        var result = DrainResult()

        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            return result
        }

        // Per-kind buckets so a book-only drain doesn't accidentally swallow
        // position items as collateral.
        let drained = await queue.dequeueNext(limit: limit)
        var booksBucket: [SyncQueueItem] = []
        var positionsBucket: [SyncQueueItem] = []
        var highlightsBucket: [SyncQueueItem] = []
        var conversationsBucket: [SyncQueueItem] = []
        var messagesBucket: [SyncQueueItem] = []
        var bookmarksBucket: [SyncQueueItem] = []
        var chapterIndexesBucket: [SyncQueueItem] = []
        for item in drained {
            switch item.kind {
            case .book:         booksBucket.append(item)
            case .position:     positionsBucket.append(item)
            case .highlight:    highlightsBucket.append(item)
            case .conversation: conversationsBucket.append(item)
            case .message:      messagesBucket.append(item)
            case .bookmark:     bookmarksBucket.append(item)
            case .chapterIndex: chapterIndexesBucket.append(item)
            }
        }

        // Books — one upload per item (no batching API today).
        for item in booksBucket {
            do {
                if let book = try await bookStore.book(item.entityId) {
                    try await bookUploader.upload(book)
                    result.booksUploaded += 1
                } else if try await metadataStore.isTombstone(entityId: item.entityId, kind: .book) {
                    try await bookUploader.uploadTombstone(item.entityId)
                    result.booksUploaded += 1
                } else {
                    // Local row gone — drop the dirty mark.
                    try await metadataStore.forget(entityId: item.entityId, kind: .book)
                }
            } catch {
                result.errors.append("book.upload: \(error)")
                await queue.enqueue(item) // re-enqueue for the next wave
            }
        }

        // Positions — batch push.
        if !positionsBucket.isEmpty {
            do {
                result.positionsPushed = try await positionUploader.pushPending(items: positionsBucket)
            } catch {
                result.errors.append("position.push: \(error)")
                for item in positionsBucket { await queue.enqueue(item) }
            }
        }

        // Highlights — batch push (live + tombstones).
        if !highlightsBucket.isEmpty {
            do {
                result.highlightsPushed = try await highlightUploader.pushPending(items: highlightsBucket)
            } catch {
                result.errors.append("highlight.push: \(error)")
                for item in highlightsBucket { await queue.enqueue(item) }
            }
        }

        // Conversations — batch push (Phase 16-04).
        if !conversationsBucket.isEmpty {
            do {
                result.conversationsPushed = try await conversationUploader.pushPending(items: conversationsBucket)
            } catch {
                result.errors.append("conversation.push: \(error)")
                for item in conversationsBucket { await queue.enqueue(item) }
            }
        }

        // Messages — batch push (Phase 16-04).
        if !messagesBucket.isEmpty {
            do {
                result.messagesPushed = try await messageUploader.pushPending(items: messagesBucket)
            } catch {
                result.errors.append("message.push: \(error)")
                for item in messagesBucket { await queue.enqueue(item) }
            }
        }

        // Bookmarks — batch push (live + tombstones), Phase 37-08.
        if !bookmarksBucket.isEmpty {
            do {
                result.bookmarksPushed = try await bookmarkUploader.pushPending(items: bookmarksBucket)
            } catch {
                result.errors.append("bookmark.push: \(error)")
                for item in bookmarksBucket { await queue.enqueue(item) }
            }
        }

        if !chapterIndexesBucket.isEmpty {
            do {
                result.chapterIndexesPushed = try await chapterIndexUploader.pushPending(items: chapterIndexesBucket)
            } catch {
                result.errors.append("chapter_index.push: \(error)")
                for item in chapterIndexesBucket { await queue.enqueue(item) }
            }
        }

        return result
    }
}
