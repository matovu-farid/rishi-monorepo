@testable import rishi
import Foundation
import Testing
import SwiftData

@Suite("Outbound managed readiness")
struct OutboundReadinessTests {
    private actor Metadata: SyncMetadataStore {
        var syncDates: [String: Date] = [:]
        var dirtyDates: [String: Date] = [:]
        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws { dirtyDates[key(entityId, kind)] = Date() }
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws { syncDates[key(entityId, kind)] = lastSyncedAt; dirtyDates[key(entityId, kind)] = nil }
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {}
        func lastSyncedAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? { syncDates[key(entityId, kind)] }
        func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? { dirtyDates[key(entityId, kind)] }
        func accept(_ id: UUID, kind: SyncEntityKind) { syncDates[key(id, kind)] = Date(); dirtyDates[key(id, kind)] = nil }
        private func key(_ id: UUID, _ kind: SyncEntityKind) -> String { "\(id):\(kind.rawValue)" }
    }

    private actor Books: BookStore {
        var rows: [BookID: Book] = [:]
        func seed(_ book: Book) { rows[book.id] = book }
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
    }

    private actor Positions: PositionStore {
        var rows: [BookID: Position] = [:]
        func seed(_ position: Position) { rows[position.bookId] = position }
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {}
    }

    private actor Highlights: HighlightStore {
        func highlights(for bookId: BookID) async throws -> [Highlight] { [] }
        func highlight(_ id: HighlightID) async throws -> Highlight? { nil }
        func upsert(_ highlight: Highlight) async throws {}
        func delete(_ id: HighlightID) async throws {}
    }

    private actor Bookmarks: BookmarkStore {
        func bookmarks(for bookId: BookID) async throws -> [Bookmark] { [] }
        func bookmark(_ id: BookmarkID) async throws -> Bookmark? { nil }
        func upsert(_ bookmark: Bookmark) async throws {}
        func delete(_ id: BookmarkID) async throws {}
    }

    private actor Conversations: ConversationStore {
        var rows: [ConversationID: Conversation] = [:]
        func seed(_ value: Conversation) { rows[value.id] = value }
        func conversations(for userId: UserID) async throws -> [Conversation] { Array(rows.values) }
        func conversation(_ id: ConversationID) async throws -> Conversation? { rows[id] }
        func upsert(_ conversation: Conversation) async throws { rows[conversation.id] = conversation }
        func delete(_ id: ConversationID) async throws { rows[id] = nil }
    }

    private actor Messages: MessageStore {
        var rows: [MessageID: Message] = [:]
        func seed(_ value: Message) { rows[value.id] = value }
        func messages(for conversationId: ConversationID) async throws -> [Message] { rows.values.filter { $0.conversationId == conversationId } }
        func message(_ id: MessageID) async throws -> Message? { rows[id] }
        func upsert(_ message: Message) async throws { rows[message.id] = message }
        func delete(_ id: MessageID) async throws { rows[id] = nil }
    }

    private struct Sources: BookSourceResolving {
        let ready: Bool
        func acquireReadableSource(for book: Book) async throws -> BookSourceLease { throw CancellationError() }
        func managedSource(for book: Book) async throws -> ManagedBookSource? {
            guard ready else { return nil }
            let fingerprint = BookFileFingerprint(
                bookID: book.id,
                ownerID: book.userId,
                sha256: "abc",
                version: ManagedFileVersion(byteCount: 3, modificationDate: .distantPast, fileIdentifier: nil, materializationRevision: UUID()),
                serverAcceptance: BookServerAcceptance(sha256: "abc", acceptedOperationID: UUID(), acceptedAt: .distantPast)
            )
            return ManagedBookSource(bookID: book.id, url: URL(fileURLWithPath: "/managed/book"), fingerprint: fingerprint, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 1, bookID: book.id, contentRevision: fingerprint.version.materializationRevision))
        }
        func awaitManagedSource(for book: Book) async throws -> ManagedBookSource {
            guard let source = try await managedSource(for: book) else { throw CancellationError() }
            return source
        }
    }

    private func makePolicy(
        ownerID: UserID,
        books: Books,
        positions: Positions,
        conversations: Conversations,
        messages: Messages,
        metadata: Metadata,
        sourceReady: Bool
    ) -> BookReadinessPolicy {
        BookReadinessPolicy(
            bookStore: books,
            positionStore: positions,
            highlightStore: Highlights(),
            bookmarkStore: Bookmarks(),
            conversationStore: conversations,
            messageStore: messages,
            chapterIndexes: nil,
            metadataStore: metadata,
            sourceResolver: Sources(ready: sourceReady),
            currentUserID: { ownerID }
        )
    }

    @Test("Pending book position stays blocked while authenticated nil-book chat remains eligible")
    func pendingBookAndNilBookConversationAreSeparated() async throws {
        let ownerID = UUID()
        let book = Book(id: UUID(), userId: ownerID, title: "Pending", formatType: .pdf, fileURL: "Books/pending.pdf")
        let books = Books(); await books.seed(book)
        let positions = Positions(); await positions.seed(Position(bookId: book.id, locator: "p1"))
        let conversations = Conversations()
        let nilBook = Conversation(userId: ownerID, bookId: nil, title: "General")
        await conversations.seed(nilBook)
        let policy = makePolicy(ownerID: ownerID, books: books, positions: positions, conversations: conversations, messages: Messages(), metadata: Metadata(), sourceReady: false)

        #expect(try await policy.classify(SyncQueueItem(entityId: book.id, kind: .position)) == .dependency(SyncQueueItem(entityId: book.id, kind: .book)))
        #expect(try await policy.classify(SyncQueueItem(entityId: nilBook.id, kind: .conversation)) == .eligible)
    }

    @Test("Messages wait for accepted conversation metadata")
    func messageWaitsForConversationAcceptance() async throws {
        let ownerID = UUID()
        let books = Books()
        let positions = Positions()
        let conversations = Conversations()
        let conversation = Conversation(userId: ownerID, bookId: nil, title: "General")
        await conversations.seed(conversation)
        let message = Message(conversationId: conversation.id, role: .user, content: "hello")
        let messages = Messages(); await messages.seed(message)
        let metadata = Metadata()
        let policy = makePolicy(ownerID: ownerID, books: books, positions: positions, conversations: conversations, messages: messages, metadata: metadata, sourceReady: true)

        #expect(try await policy.classify(SyncQueueItem(entityId: message.id, kind: .message)) == .dependency(SyncQueueItem(entityId: conversation.id, kind: .conversation)))
        await metadata.accept(conversation.id, kind: .conversation)
        #expect(try await policy.classify(SyncQueueItem(entityId: message.id, kind: .message)) == .eligible)
    }
    private actor DiscoverySources: BookSourceResolving {
        var requested = Set<BookID>()
        let unavailable: Set<BookID>
        let gate: DiscoveryGate?
        init(unavailable: Set<BookID> = [], gate: DiscoveryGate? = nil) {
            self.unavailable = unavailable; self.gate = gate
        }
        func acquireReadableSource(for book: Book) async throws -> BookSourceLease { throw CancellationError() }
        func managedSource(for book: Book) async throws -> ManagedBookSource? {
            requested.insert(book.id)
            if let gate { await gate.suspend() }
            return try await Sources(ready: !unavailable.contains(book.id)).managedSource(for: book)
        }
        func awaitManagedSource(for book: Book) async throws -> ManagedBookSource {
            guard let source = try await managedSource(for: book) else { throw CancellationError() }
            return source
        }
        func requests() -> Set<BookID> { requested }
    }

    private actor DiscoveryGate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []
        func suspend() async {
            await withCheckedContinuation {
                continuation = $0; entered = true
                waiters.forEach { $0.resume() }; waiters.removeAll()
            }
        }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private actor DiscoveryAuthority {
        var current = true
        var provenance = true
        func isCurrent() -> Bool { current }
        func isValidSource() -> Bool { provenance }
        func switchAccount() { current = false }
        func changeFingerprint() { provenance = false }
    }

    private func discoveryPolicy(owner: UserID, books: Books, metadata: any SyncMetadataStore,
        sources: any BookSourceResolving,
        revalidate: @escaping @Sendable (Book, ManagedBookSource) async throws -> Bool = { _, _ in true }
    ) -> BookReadinessPolicy {
        BookReadinessPolicy(bookStore: books, positionStore: Positions(), highlightStore: Highlights(),
            bookmarkStore: Bookmarks(), conversationStore: Conversations(), messageStore: Messages(),
            chapterIndexes: nil, metadataStore: metadata, sourceResolver: sources,
            currentUserID: { owner }, revalidateManagedSource: revalidate)
    }

    @Test("Recovery finds only never-synced ready books and preserves dirty operation IDs")
    @MainActor
    func recoveryPrefiltersRealMetadata() async throws {
        let owner = UUID()
        let books = Books()
        func book(_ name: String, ownerID: UUID? = nil) -> Book {
            Book(userId: ownerID ?? owner, title: name, formatType: .pdf, fileURL: "Books/\(name).pdf")
        }
        let missing = book("missing")
        let cleanLegacy = book("cleanLegacy")
        let dirty = book("dirty")
        let legacyDirty = book("legacyDirty")
        let deleted = book("deleted")
        let wrongOwner = book("wrongOwner", ownerID: UUID())
        let unavailable = book("unavailable")
        for value in [missing, cleanLegacy, dirty, legacyDirty, deleted, wrongOwner, unavailable] { await books.seed(value) }
        let container = try SyncMetadataStoreBootstrap.makeContainer(inMemory: true)
        let operation = UUID()
        let context = ModelContext(container)
        context.insert(SyncMetadataRow(entityId: legacyDirty.id.uuidString, entityType: SyncEntityKind.book.rawValue,
            dirtyAt: nil, operationId: operation, dirty: true))
        try context.save()
        let metadata = await SwiftDataSyncMetadataStore.make(container: container)
        try await metadata.markClean(entityId: cleanLegacy.id, kind: .book, lastSyncedAt: .distantPast, remoteEtag: nil)
        try await metadata.markDirty(entityId: dirty.id, kind: .book)
        let dirtyOperation = try await metadata.operationId(entityId: dirty.id, kind: .book)
        try await metadata.applyLocalBookTombstone(deleted.id, mutation: {})
        let sources = DiscoverySources(unavailable: [unavailable.id])
        let policy = discoveryPolicy(owner: owner, books: books, metadata: metadata, sources: sources)
        let recovered = try await policy.reconcileUntrackedBooks(expectedUserID: owner, isCurrentAccount: { true })
        #expect(recovered == [SyncQueueItem(entityId: missing.id, kind: .book)])
        #expect(await sources.requests() == [missing.id, unavailable.id])
        #expect(try await metadata.operationId(entityId: dirty.id, kind: .book) == dirtyOperation)
        #expect(try await metadata.operationId(entityId: legacyDirty.id, kind: .book) == operation)
        #expect(try await metadata.dirtyAt(entityId: legacyDirty.id, kind: .book) == nil)
        #expect(try await metadata.dirtyAt(entityId: missing.id, kind: .book) != nil)
        #expect(try await metadata.isTombstone(entityId: deleted.id, kind: .book))
    }

    @Test("Source resolution leaves deletion free to commit and rechecks account/provenance", arguments: ["delete", "account", "fingerprint", "path", "dirty"])
    func recoveryRejectsChangesDuringResolution(mode: String) async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Candidate", formatType: .pdf, fileURL: "Books/candidate.pdf")
        let books = Books(); await books.seed(book)
        let metadata = try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        let gate = DiscoveryGate()
        let authority = DiscoveryAuthority()
        let policy = discoveryPolicy(owner: owner, books: books, metadata: metadata,
            sources: DiscoverySources(gate: gate), revalidate: { _, _ in await authority.isValidSource() })
        let discovery = Task {
            try await policy.reconcileUntrackedBooks(expectedUserID: owner, isCurrentAccount: { await authority.isCurrent() })
        }
        await gate.waitForEntry()
        var operation: UUID?
        switch mode {
        case "delete":
            // This await must finish while the source resolver remains suspended.
            try await metadata.applyLocalBookTombstone(book.id) { try await books.delete(book.id) }
            #expect(try await books.book(book.id) == nil)
        case "account": await authority.switchAccount()
        case "fingerprint": await authority.changeFingerprint()
        case "path":
            var replacement = book; replacement.fileURL = "Books/replacement.pdf"
            try await books.upsert(replacement)
        default:
            try await metadata.markDirty(entityId: book.id, kind: .book)
            operation = try await metadata.operationId(entityId: book.id, kind: .book)
        }
        await gate.release()
        #expect(try await discovery.value.isEmpty)
        if mode == "dirty" {
            #expect(try await metadata.operationId(entityId: book.id, kind: .book) == operation)
        } else if mode != "delete" {
            #expect(try await metadata.allDirty().isEmpty)
        }
    }

    @Test("Reconciliation stays disabled without a captured-source validator")
    func recoveryRequiresExplicitSourceValidation() async throws {
        let owner = UUID()
        let books = Books()
        let book = Book(userId: owner, title: "Candidate", formatType: .pdf, fileURL: "Books/candidate.pdf")
        await books.seed(book)
        let metadata = try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        let policy = BookReadinessPolicy(bookStore: books, positionStore: Positions(), highlightStore: Highlights(),
            bookmarkStore: Bookmarks(), conversationStore: Conversations(), messageStore: Messages(), chapterIndexes: nil,
            metadataStore: metadata, sourceResolver: Sources(ready: true), currentUserID: { owner })
        #expect(try await policy.reconcileUntrackedBooks(expectedUserID: owner, isCurrentAccount: { true }).isEmpty)
        #expect(try await metadata.allDirty().isEmpty)
    }

}
