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
        var rejectedPositions: [PositionUploader.RejectedSnapshot] = []
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
    private let currentUserId: @Sendable () async -> UserID?
    private let readinessPolicy: BookReadinessPolicy?

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
        let currentUserId: @Sendable () async -> UserID?
        let readinessPolicy: BookReadinessPolicy?
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
        self.currentUserId = dependencies.currentUserId
        self.readinessPolicy = dependencies.readinessPolicy
    }

    /// Drain up to `limit` queue items and push them by kind.
    func drain(limit: Int, expectedUserId: UserID?) async -> DrainResult {
        var result = DrainResult()

        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            return result
        }
        guard await isExpected(expectedUserId) else {
            result.errors.append("account switched during outbound sync")
            return result
        }

        // Per-kind buckets so a book-only drain doesn't accidentally swallow
        // position items as collateral.
        let drained: [SyncQueueItem]
        if let readinessPolicy {
            let snapshot = await queue.snapshot()
            var classifications: [(SyncQueueItem, BookReadinessPolicy.Decision)] = []
            var dependencyIDs = Set<UUID>()
            var newDependencies: [SyncQueueItem] = []
            for item in snapshot {
                do {
                    let decision = try await readinessPolicy.classify(item)
                    classifications.append((item, decision))
                    if case let .dependency(dependency) = decision {
                        dependencyIDs.insert(dependency.entityId)
                        if !snapshot.contains(where: { $0 == dependency }) {
                            try await metadataStore.markDirty(entityId: dependency.entityId, kind: dependency.kind)
                            await queue.enqueue(dependency)
                            newDependencies.append(dependency)
                        }
                    }
                } catch {
                    result.errors.append("readiness.classify: \(error)")
                }
            }
            for dependency in newDependencies {
                do {
                    let decision = try await readinessPolicy.classify(dependency)
                    classifications.append((dependency, decision))
                } catch {
                    result.errors.append("readiness.classify: \(error)")
                }
            }
            let eligible = classifications.compactMap { item, decision -> SyncQueueItem? in
                (decision == .eligible || decision == .discard) ? item : nil
            }.sorted { left, right in
                let leftDependency = left.kind == .book && dependencyIDs.contains(left.entityId)
                let rightDependency = right.kind == .book && dependencyIDs.contains(right.entityId)
                if leftDependency != rightDependency { return leftDependency }
                if left.kind != right.kind { return left.kind == .book }
                return left.entityId.uuidString < right.entityId.uuidString
            }
            drained = await queue.claimEligible(items: Array(eligible.prefix(max(0, limit))))
        } else {
            drained = await queue.dequeueNext(limit: limit)
        }
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
        var attemptedCount = drained.count

        // Books — one upload per item (no batching API today).
        for (index, item) in booksBucket.enumerated() {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(Array(booksBucket.dropFirst(index)) + positionsBucket + highlightsBucket + conversationsBucket + messagesBucket + bookmarksBucket + chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                if try await metadataStore.isTombstone(entityId: item.entityId, kind: .book) {
                    // Acknowledgement can race queue admission/classification.
                    // Drop clean resident work; genuine pending deletes upload.
                    if try await bookUploader.uploadTombstone(item.entityId) { result.booksUploaded += 1 }
                } else if let book = try await bookStore.book(item.entityId) {
                    try await bookUploader.upload(book)
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

        // Parent uploads can establish durable acceptance in this wave. Recheck
        // resident children once so successful parent responses unblock them
        // without a second sync trigger.
        if let readinessPolicy, !booksBucket.isEmpty {
            let candidates = await newlyEligible(
                limit: max(0, limit - attemptedCount),
                kinds: [.position, .highlight, .conversation, .message, .bookmark, .chapterIndex],
                policy: readinessPolicy
            )
            attemptedCount += candidates.count
            for item in candidates {
                switch item.kind {
                case .book: booksBucket.append(item)
                case .position: positionsBucket.append(item)
                case .highlight: highlightsBucket.append(item)
                case .conversation: conversationsBucket.append(item)
                case .message: messagesBucket.append(item)
                case .bookmark: bookmarksBucket.append(item)
                case .chapterIndex: chapterIndexesBucket.append(item)
                }
            }
        }

        // Positions — batch push.
        if !positionsBucket.isEmpty {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(positionsBucket + highlightsBucket + conversationsBucket + messagesBucket + bookmarksBucket + chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                let positions = try await positionUploader.pushPendingWithOutcomes(items: positionsBucket)
                result.positionsPushed = positions.acceptedCount
                result.rejectedPositions = positions.rejected
            } catch {
                result.errors.append("position.push: \(error)")
                for item in positionsBucket { await queue.enqueue(item) }
            }
        }

        // Highlights — batch push (live + tombstones).
        if !highlightsBucket.isEmpty {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(highlightsBucket + conversationsBucket + messagesBucket + bookmarksBucket + chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                result.highlightsPushed = try await highlightUploader.pushPending(items: highlightsBucket)
            } catch {
                result.errors.append("highlight.push: \(error)")
                for item in highlightsBucket { await queue.enqueue(item) }
            }
        }

        // Conversations — batch push (Phase 16-04).
        if !conversationsBucket.isEmpty {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(conversationsBucket + messagesBucket + bookmarksBucket + chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                result.conversationsPushed = try await conversationUploader.pushPending(items: conversationsBucket)
            } catch {
                result.errors.append("conversation.push: \(error)")
                for item in conversationsBucket { await queue.enqueue(item) }
            }
        }

        if let readinessPolicy, !conversationsBucket.isEmpty {
            let candidates = await newlyEligible(limit: max(0, limit - attemptedCount), kinds: [.message], policy: readinessPolicy)
            attemptedCount += candidates.count
            for item in candidates {
                messagesBucket.append(item)
            }
        }

        // Messages — batch push (Phase 16-04).
        if !messagesBucket.isEmpty {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(messagesBucket + bookmarksBucket + chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                result.messagesPushed = try await messageUploader.pushPending(items: messagesBucket)
            } catch {
                result.errors.append("message.push: \(error)")
                for item in messagesBucket { await queue.enqueue(item) }
            }
        }

        // Bookmarks — batch push (live + tombstones), Phase 37-08.
        if !bookmarksBucket.isEmpty {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(bookmarksBucket + chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                result.bookmarksPushed = try await bookmarkUploader.pushPending(items: bookmarksBucket)
            } catch {
                result.errors.append("bookmark.push: \(error)")
                for item in bookmarksBucket { await queue.enqueue(item) }
            }
        }

        if !chapterIndexesBucket.isEmpty {
            do {
                guard await isExpected(expectedUserId) else {
                    await requeue(chapterIndexesBucket)
                    result.errors.append("account switched during outbound sync")
                    return result
                }
                result.chapterIndexesPushed = try await chapterIndexUploader.pushPending(items: chapterIndexesBucket)
            } catch {
                result.errors.append("chapter_index.push: \(error)")
                for item in chapterIndexesBucket { await queue.enqueue(item) }
            }
        }

        return result
    }

    private func isExpected(_ expectedUserId: UserID?) async -> Bool {
        let current = await currentUserId()
        return expectedUserId == current
    }

    private func requeue(_ items: [SyncQueueItem]) async {
        for item in items {
            await queue.enqueue(item)
        }
    }

    private func newlyEligible(limit: Int, kinds: Set<SyncEntityKind>, policy: BookReadinessPolicy) async -> [SyncQueueItem] {
        guard limit > 0 else { return [] }
        let snapshot = await queue.snapshot()
        var eligible: [SyncQueueItem] = []
        for item in snapshot {
            guard kinds.contains(item.kind) else { continue }
            guard (try? await policy.classify(item)) == .eligible else { continue }
            eligible.append(item)
            if eligible.count == limit { break }
        }
        return await queue.claimEligible(items: eligible)
    }
}
