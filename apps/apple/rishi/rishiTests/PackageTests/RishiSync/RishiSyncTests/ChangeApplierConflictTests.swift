@testable import rishi
import Testing
import Foundation




/// SYNC-04 — ChangeApplier conflict resolution policy:
///   - Positions: last-write-wins by `updatedAt`. Server's updatedAt is
///     authoritative; ties favor local (server-newer overwrites only when
///     strictly newer).
///   - Highlights: merge by ID. Same ID + diverged content → latest
///     `createdAt` wins. Different IDs are kept (no conflict).
///   - Book metadata: deleted=true cascades through bookStore.delete and
///     retains a clean metadata tombstone. Live rows upsert into BookStore.
///   - Conversation / Message kinds are accepted but skipped (Phase 9 will
///     wire) — metadata.markClean still called so we don't echo the cursor.
@Suite("ChangeApplier — SYNC-04 conflict resolution", .serialized)
struct ChangeApplierConflictTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var cleanCalls: [(UUID, SyncEntityKind, Date, String?)] = []
        var forgetCalls: [(UUID, SyncEntityKind)] = []
        var tombstoneAcknowledgements: [(UUID, SyncEntityKind)] = []
        var remoteSeenCalls: [(UUID, SyncEntityKind, Date)] = []
        var dirtyRows: [String: Date] = [:]

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
        }
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {
            forgetCalls.append((entityId, kind))
        }
        func markCleanIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
            return true
        }
        func acknowledgeTombstoneIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
            tombstoneAcknowledgements.append((entityId, kind))
            return true
        }
        func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
            dirtyRows["\(entityId.uuidString):\(kind.rawValue)"]
        }
        func seedDirty(_ entityId: UUID, kind: SyncEntityKind) {
            dirtyRows["\(entityId.uuidString):\(kind.rawValue)"] = Date(timeIntervalSince1970: 1_700_000_000)
        }
        func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws {
            remoteSeenCalls.append((entityId, kind, updatedAt))
        }
        func cleaned() -> [(UUID, SyncEntityKind, Date, String?)] { cleanCalls }
        func forgotten() -> [(UUID, SyncEntityKind)] { forgetCalls }
        func acknowledgedTombstones() -> [(UUID, SyncEntityKind)] { tombstoneAcknowledgements }
        func remoteSeen() -> [(UUID, SyncEntityKind, Date)] { remoteSeenCalls }
    }

    private actor StubBookStore: BookStore {
        var rows: [BookID: Book] = [:]
        func seed(_ book: Book) { rows[book.id] = book }
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
        func count() -> Int { rows.count }
    }

    private actor StubPositionStore: PositionStore {
        var rows: [BookID: Position] = [:]
        func seed(_ position: Position) { rows[position.bookId] = position }
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key { rows[key] = nil }
        }
        func snapshot() -> [Position] { Array(rows.values) }
    }

    private actor StubHighlightStore: HighlightStore {
        var rows: [HighlightID: Highlight] = [:]
        func seed(_ highlight: Highlight) { rows[highlight.id] = highlight }
        func highlights(for bookId: BookID) async throws -> [Highlight] {
            rows.values.filter { $0.bookId == bookId }
        }
        func highlight(_ id: HighlightID) async throws -> Highlight? { rows[id] }
        func upsert(_ highlight: Highlight) async throws { rows[highlight.id] = highlight }
        func delete(_ id: HighlightID) async throws { rows[id] = nil }
        func snapshot() -> [Highlight] { Array(rows.values) }
    }

    private actor StubBookmarkStore: BookmarkStore {
        var rows: [BookmarkID: Bookmark] = [:]
        func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
            rows.values.filter { $0.bookId == bookId }
        }
        func bookmark(_ id: BookmarkID) async throws -> Bookmark? { rows[id] }
        func upsert(_ bookmark: Bookmark) async throws { rows[bookmark.id] = bookmark }
        func delete(_ id: BookmarkID) async throws { rows[id] = nil }
    }

    private actor CleanupProbe {
        var ids: [BookID] = []
        func record(_ id: BookID) { ids.append(id) }
        func snapshot() -> [BookID] { ids }
    }

    // MARK: - Helpers

    private func makeApplier(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        metadata: any SyncMetadataStore,
        currentUserId: @escaping @Sendable () async -> UserID? = { nil },
        bookMaterialCleanup: (@Sendable (Book) async throws -> Void)? = nil
    ) -> ChangeApplier {
        ChangeApplier(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: StubBookmarkStore(),
            metadataStore: metadata,
            currentUserId: currentUserId,
            bookMaterialCleanup: bookMaterialCleanup
        )
    }

    private func positionChange(_ position: Position, at: Date) throws -> SyncChange {
        let payload = try SyncPayloadCodec.encodePosition(position)
        return SyncChange(
            kind: SyncEntityKind.position.rawValue,
            id: position.id,
            payload: payload,
            updatedAt: at,
            deleted: false
        )
    }

    private func highlightChange(_ highlight: Highlight, at: Date, deleted: Bool = false) throws -> SyncChange {
        let payload = try SyncPayloadCodec.encodeHighlight(highlight)
        return SyncChange(
            kind: SyncEntityKind.highlight.rawValue,
            id: highlight.id,
            payload: payload,
            updatedAt: at,
            deleted: deleted
        )
    }

    // MARK: - Tests (≥6 required by plan)

    @Test("Inbound changes for a different account are rejected without mutating stores")
    func inboundChangeForDifferentAccountIsRejected() async throws {
        let expectedUserId = UUID()
        let activeUserId = UUID()
        let position = Position(
            bookId: UUID(),
            locator: "pdf-v1:page:12",
            percentComplete: 0.4,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let positionStore = StubPositionStore()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata,
            currentUserId: { activeUserId }
        )

        let change = try positionChange(position, at: position.updatedAt)
        let result = await applier.apply([change], expectedUserId: expectedUserId)

        #expect(result.applied == 0)
        #expect(result.errors.contains("account switched during inbound sync"))
        #expect(await positionStore.snapshot().isEmpty)
        #expect(await metadata.cleaned().isEmpty)
    }

    @Test("Position: local newer than remote → conflict, no overwrite")
    func positionLocalNewerWins() async throws {
        let bookId = UUID()
        let localPosition = Position(
            bookId: bookId,
            locator: "pdf-v1:page:10",
            percentComplete: 0.5,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let remotePosition = Position(
            id: localPosition.id,
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let positionStore = StubPositionStore()
        await positionStore.seed(localPosition)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let change = try positionChange(remotePosition, at: remotePosition.updatedAt)
        let result = await applier.apply([change])

        #expect(result.conflicts == 1)
        #expect(result.applied == 0)

        let stored = await positionStore.snapshot()
        #expect(stored.first?.locator == "pdf-v1:page:10")
        #expect(stored.first?.percentComplete == 0.5)
    }

    @Test("Local-wins conflict records remote seen without clearing local work")
    func localWinsRecordsRemoteSeen() async throws {
        let positionStore = StubPositionStore()
        let bookId = UUID()
        let local = Position(
            bookId: bookId,
            locator: "pdf-v1:page:10",
            percentComplete: 0.5,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        await positionStore.seed(local)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )
        let remote = Position(
            bookId: bookId,
            locator: "pdf-v1:page:2",
            percentComplete: 0.1,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        _ = await applier.apply([try positionChange(remote, at: remote.updatedAt)])

        let seen = await metadata.remoteSeen()
        #expect(seen.count == 1)
        #expect(seen.first?.0 == bookId)
        #expect(seen.first?.1 == .position)
    }

    @Test("Duplicate remote replay records remote seen")
    func duplicateRemoteReplayRecordsRemoteSeen() async throws {
        let positionStore = StubPositionStore()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )
        let position = Position(
            bookId: UUID(),
            locator: "pdf-v1:page:4",
            percentComplete: 0.2,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let change = try positionChange(position, at: position.updatedAt)

        _ = await applier.apply([change])
        _ = await applier.apply([change])

        #expect((await metadata.remoteSeen()).count == 1)
    }

    @Test("Position: remote newer than local → upsert remote + markClean")
    func positionRemoteNewerWins() async throws {
        let bookId = UUID()
        let localPosition = Position(
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let remotePosition = Position(
            id: localPosition.id,
            bookId: bookId,
            locator: "pdf-v1:page:10",
            percentComplete: 0.5,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let positionStore = StubPositionStore()
        await positionStore.seed(localPosition)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let change = try positionChange(remotePosition, at: remotePosition.updatedAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)

        let stored = await positionStore.snapshot()
        #expect(stored.first?.locator == "pdf-v1:page:10")
        #expect(stored.first?.percentComplete == 0.5)

        // markClean uses change.updatedAt as the cursor against bookId.
        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 1)
        #expect(cleaned[0].0 == bookId)
        #expect(cleaned[0].1 == .position)
        #expect(cleaned[0].2.timeIntervalSince1970 == 2_000_000_000)
    }

    @Test("Highlight: new ID remote-only → upserted")
    func highlightNewRemoteIdUpserted() async throws {
        let highlightStore = StubHighlightStore()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let remote = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .yellow,
            text: "remote-only"
        )
        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await highlightStore.snapshot()
        #expect(stored.count == 1)
        #expect(stored.first?.id == remote.id)
    }

    @Test("Highlight: new ID local-only → kept (no change for that id)")
    func highlightNewLocalIdSurvives() async throws {
        let highlightStore = StubHighlightStore()
        let local = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .pink,
            text: "local-only"
        )
        await highlightStore.seed(local)

        // Remote sends a DIFFERENT id — different highlight, both survive.
        let remote = Highlight(
            bookId: local.bookId,
            locatorStart: "epub-v1:cfi-b",
            locatorEnd: "epub-v1:cfi-b",
            color: .blue,
            text: "remote-different-id"
        )
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await highlightStore.snapshot()
        // BOTH ids present — merge-by-id semantics keep distinct ids.
        let ids = Set(stored.map(\.id))
        #expect(ids == Set([local.id, remote.id]))
    }

    @Test("Highlight: same ID, local newer (createdAt) → conflict, no overwrite")
    func highlightSameIdLocalNewerWins() async throws {
        let highlightStore = StubHighlightStore()
        let highlightId = UUID()
        let local = Highlight(
            id: highlightId,
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .pink,
            text: "newer-local",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        await highlightStore.seed(local)

        let remote = Highlight(
            id: highlightId,
            bookId: local.bookId,
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .green,
            text: "older-remote",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.conflicts == 1)
        #expect(result.applied == 0)
        let stored = await highlightStore.snapshot()
        #expect(stored.first?.text == "newer-local")
        #expect(stored.first?.color == .pink)
    }

    @Test("Highlight: same ID, remote newer → overwrites local")
    func highlightSameIdRemoteNewerWins() async throws {
        let highlightStore = StubHighlightStore()
        let highlightId = UUID()
        let local = Highlight(
            id: highlightId,
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .pink,
            text: "older-local",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        await highlightStore.seed(local)

        let remote = Highlight(
            id: highlightId,
            bookId: local.bookId,
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .green,
            text: "newer-remote",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)
        let stored = await highlightStore.snapshot()
        #expect(stored.first?.text == "newer-remote")
        #expect(stored.first?.color == .green)
    }

    @Test("Highlight: deleted=true → highlightStore.delete + metadata.forget")
    func highlightTombstoneDeletes() async throws {
        let highlightStore = StubHighlightStore()
        let local = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .yellow,
            text: "to-delete"
        )
        await highlightStore.seed(local)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(local, at: Date(), deleted: true)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await highlightStore.snapshot()
        #expect(stored.isEmpty)
        let forgotten = await metadata.forgotten()
        #expect(forgotten.count == 1)
        #expect(forgotten[0].0 == local.id)
        #expect(forgotten[0].1 == .highlight)
    }

    @Test("Book: deleted=true tombstone → bookStore.delete + retained metadata barrier")
    func bookDeletedTombstone() async throws {
        let bookStore = StubBookStore()
        let book = Book(
            userId: UUID(),
            title: "Doomed",
            formatType: .epub,
            fileURL: "Books/x.epub"
        )
        await bookStore.seed(book)
        let metadata = StubMetadata()
        let cleanup = CleanupProbe()
        let applier = makeApplier(
            bookStore: bookStore,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata,
            bookMaterialCleanup: { book in await cleanup.record(book.id) }
        )

        // Tombstone — payload is irrelevant for delete path.
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let count = await bookStore.count()
        #expect(count == 0)
        #expect(await cleanup.snapshot() == [book.id])
        let acknowledged = await metadata.acknowledgedTombstones()
        #expect(acknowledged.count == 1)
        #expect(acknowledged.first?.0 == book.id)
        #expect(acknowledged.first?.1 == .book)
    }

    @Test("Book: remote tombstone wins over a stale local live mutation")
    func remoteBookDeleteClearsStaleDirtyLocalCopy() async throws {
        let bookStore = StubBookStore()
        let book = Book(
            userId: UUID(),
            title: "Imported before remote delete",
            formatType: .epub,
            fileURL: "Books/stale.epub"
        )
        await bookStore.seed(book)
        let metadata = StubMetadata()
        await metadata.seedDirty(book.id, kind: .book)
        let applier = makeApplier(
            bookStore: bookStore,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let result = await applier.apply([SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)
        #expect(await bookStore.count() == 0)
        #expect((await metadata.acknowledgedTombstones()).contains { $0.0 == book.id && $0.1 == .book })
    }

    /// Phase 16-05 regression guard: chat sync moved to dedicated
    /// `/api/sync/conversations` + `/api/sync/messages` endpoints driven
    /// directly by `SyncEngine.runOnce` (bypassing `ChangeApplier`). The
    /// legacy `.conversation` / `.message` branch in `ChangeApplier.apply`
    /// is preserved as a defensive markClean no-op so any row that DOES
    /// somehow arrive via the legacy `/api/sync/changes` envelope still
    /// advances the cursor instead of looping. This test pins that branch.
    @Test("Phase 16-05 regression: legacy SyncChange.conversation still skipped + markClean'd")
    func phase16LegacyConversationStillSkipped() async throws {
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let convoChange = SyncChange(
            kind: SyncEntityKind.conversation.rawValue,
            id: UUID(),
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            deleted: false
        )

        let result = await applier.apply([convoChange])
        #expect(result.skipped == 1)
        #expect(result.applied == 0)
        #expect(result.errors.isEmpty)

        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 1)
        #expect(cleaned[0].1 == .conversation)
    }

    @Test("Conversation + Message kinds → skipped (Phase 9) but markClean still called")
    func phase9KindsAreSkippedNotErrored() async throws {
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let convoChange = SyncChange(
            kind: SyncEntityKind.conversation.rawValue,
            id: UUID(),
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: false
        )
        let msgChange = SyncChange(
            kind: SyncEntityKind.message.rawValue,
            id: UUID(),
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            deleted: false
        )

        let result = await applier.apply([convoChange, msgChange])
        #expect(result.skipped == 2)
        #expect(result.applied == 0)
        #expect(result.errors.isEmpty)

        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 2)
        #expect(Set(cleaned.map(\.1)) == Set([.conversation, .message]))
    }
}
