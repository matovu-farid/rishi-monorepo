@testable import rishi
import Testing
import Foundation




/// Phase 37 Plan 37-08 — ChangeApplier.applyBookmark (INBOUND arm).
///
/// This is the omission the 37-07 research caught: without a `.bookmark` arm an
/// inbound bookmark hits the "unknown kind" branch and is silently dropped.
/// Mirrors ChangeApplierConflictTests' highlight cases:
///   - live remote bookmark -> bookmarkStore.upsert + applied + markClean(.bookmark)
///   - deleted=true -> bookmarkStore.delete + forget(.bookmark)
///   - LWW: local.createdAt >= remote.createdAt keeps local (conflicts += 1, no echo)
@Suite("ChangeApplier — bookmark inbound", .serialized)
struct ChangeApplierBookmarkTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var cleanCalls: [(UUID, SyncEntityKind, Date, String?)] = []
        var forgetCalls: [(UUID, SyncEntityKind)] = []

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
        func cleaned() -> [(UUID, SyncEntityKind, Date, String?)] { cleanCalls }
        func forgotten() -> [(UUID, SyncEntityKind)] { forgetCalls }
    }

    private actor StubBookStore: BookStore {
        var rows: [BookID: Book] = [:]
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
    }

    private actor StubPositionStore: PositionStore {
        var rows: [BookID: Position] = [:]
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key { rows[key] = nil }
        }
    }

    private actor StubHighlightStore: HighlightStore {
        var rows: [HighlightID: Highlight] = [:]
        func highlights(for bookId: BookID) async throws -> [Highlight] {
            rows.values.filter { $0.bookId == bookId }
        }
        func highlight(_ id: HighlightID) async throws -> Highlight? { rows[id] }
        func upsert(_ highlight: Highlight) async throws { rows[highlight.id] = highlight }
        func delete(_ id: HighlightID) async throws { rows[id] = nil }
    }

    private actor StubBookmarkStore: BookmarkStore {
        var rows: [BookmarkID: Bookmark] = [:]
        func seed(_ bookmark: Bookmark) { rows[bookmark.id] = bookmark }
        func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
            rows.values.filter { $0.bookId == bookId }
        }
        func bookmark(_ id: BookmarkID) async throws -> Bookmark? { rows[id] }
        func upsert(_ bookmark: Bookmark) async throws { rows[bookmark.id] = bookmark }
        func delete(_ id: BookmarkID) async throws { rows[id] = nil }
        func snapshot() -> [Bookmark] { Array(rows.values) }
    }

    // MARK: - Helpers

    private func makeApplier(
        bookmarkStore: any BookmarkStore,
        metadata: any SyncMetadataStore
    ) -> ChangeApplier {
        ChangeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            bookmarkStore: bookmarkStore,
            metadataStore: metadata
        )
    }

    private func bookmarkChange(_ bookmark: Bookmark, at: Date, deleted: Bool = false) throws -> SyncChange {
        let payload = try SyncPayloadCodec.encodeBookmark(bookmark)
        return SyncChange(
            kind: SyncEntityKind.bookmark.rawValue,
            id: bookmark.id,
            payload: payload,
            updatedAt: at,
            deleted: deleted
        )
    }

    // MARK: - Tests

    @Test("Inbound live bookmark -> bookmarkStore.upsert + applied + markClean(.bookmark)")
    func liveBookmarkUpserted() async throws {
        let bookmarkStore = StubBookmarkStore()
        let metadata = StubMetadata()
        let applier = makeApplier(bookmarkStore: bookmarkStore, metadata: metadata)

        let remote = Bookmark(
            bookId: UUID(),
            locator: "epub-v1:cfi",
            label: "L",
            snippet: "S",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let change = try bookmarkChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)
        let stored = await bookmarkStore.snapshot()
        #expect(stored.count == 1)
        #expect(stored.first?.id == remote.id)
        #expect(stored.first?.locator == "epub-v1:cfi")

        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 1)
        #expect(cleaned[0].0 == remote.id)
        #expect(cleaned[0].1 == .bookmark)
    }

    @Test("Inbound deleted bookmark -> bookmarkStore.delete + forget(.bookmark)")
    func deletedBookmarkRemoved() async throws {
        let bookmarkStore = StubBookmarkStore()
        let local = Bookmark(
            bookId: UUID(),
            locator: "pdf-v1:page:3",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await bookmarkStore.seed(local)
        let metadata = StubMetadata()
        let applier = makeApplier(bookmarkStore: bookmarkStore, metadata: metadata)

        let change = try bookmarkChange(local, at: Date(), deleted: true)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await bookmarkStore.snapshot()
        #expect(stored.isEmpty)
        let forgotten = await metadata.forgotten()
        #expect(forgotten.count == 1)
        #expect(forgotten[0].0 == local.id)
        #expect(forgotten[0].1 == .bookmark)
    }

    @Test("LWW: same id, local.createdAt >= remote -> conflict, no overwrite (no echo)")
    func lwwLocalNewerWins() async throws {
        let bookmarkStore = StubBookmarkStore()
        let id = UUID()
        let local = Bookmark(
            id: id,
            bookId: UUID(),
            locator: "newer-local",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        await bookmarkStore.seed(local)

        let remote = Bookmark(
            id: id,
            bookId: local.bookId,
            locator: "older-remote",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let metadata = StubMetadata()
        let applier = makeApplier(bookmarkStore: bookmarkStore, metadata: metadata)

        let change = try bookmarkChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.conflicts == 1)
        #expect(result.applied == 0)
        let stored = await bookmarkStore.snapshot()
        #expect(stored.first?.locator == "newer-local")
    }

    @Test("LWW: same id, remote newer -> overwrites local")
    func lwwRemoteNewerWins() async throws {
        let bookmarkStore = StubBookmarkStore()
        let id = UUID()
        let local = Bookmark(
            id: id,
            bookId: UUID(),
            locator: "older-local",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        await bookmarkStore.seed(local)

        let remote = Bookmark(
            id: id,
            bookId: local.bookId,
            locator: "newer-remote",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let metadata = StubMetadata()
        let applier = makeApplier(bookmarkStore: bookmarkStore, metadata: metadata)

        let change = try bookmarkChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)
        let stored = await bookmarkStore.snapshot()
        #expect(stored.first?.locator == "newer-remote")
    }

    @Test("Inbound bookmark no longer hits the unknown-kind branch")
    func bookmarkKindNotUnknown() async throws {
        let bookmarkStore = StubBookmarkStore()
        let metadata = StubMetadata()
        let applier = makeApplier(bookmarkStore: bookmarkStore, metadata: metadata)

        let remote = Bookmark(bookId: UUID(), locator: "epub-v1:cfi")
        let change = try bookmarkChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.errors.isEmpty)
        #expect(result.applied == 1)
    }
}
