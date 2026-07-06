import Testing
import Foundation
import os
@testable import RishiSync
import RishiCore
import RishiCore

/// Phase 37 Plan 37-08 — BookmarkUploader: drain pending bookmarks -> POST -> markClean / forget.
/// Clones HighlightUploaderTests. The wire shape (kind "bookmark", live + tombstone)
/// is locked against the 37-07 worker half.
@Suite("BookmarkUploader", .serialized)
struct BookmarkUploaderTests {

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

        func cleanIds() -> [UUID] { cleanCalls.map(\.0) }
        func cleanKinds() -> [SyncEntityKind] { cleanCalls.map(\.1) }
        func forgetIds() -> [UUID] { forgetCalls.map(\.0) }
        func forgetKinds() -> [SyncEntityKind] { forgetCalls.map(\.1) }
    }

    private actor StubBookmarkStore: BookmarkStore {
        private var rows: [BookmarkID: Bookmark] = [:]

        func seed(_ rows: [Bookmark]) { for r in rows { self.rows[r.id] = r } }
        func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
            rows.values.filter { $0.bookId == bookId }
        }
        func bookmark(_ id: BookmarkID) async throws -> Bookmark? { rows[id] }
        func upsert(_ bookmark: Bookmark) async throws { rows[bookmark.id] = bookmark }
        func delete(_ id: BookmarkID) async throws { rows[id] = nil }
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BookmarkUploaderMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    private let acceptedAtUnix: TimeInterval = 1_780_000_000

    // MARK: - Tests

    @Test("Happy path: one pending bookmark -> POST /api/sync/push -> markClean(.bookmark)")
    func happyPath() async throws {
        BookmarkUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubBookmarkStore()

        let bookmark = Bookmark(
            bookId: UUID(),
            locator: "epub-v1:cfi",
            label: "Ch 1",
            snippet: "Opening line",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([bookmark])

        let acceptedAtRef = acceptedAtUnix - 978_307_200
        BookmarkUploaderMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sync/push")
            let body = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(body.utf8), nil)
        }

        let uploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: bookmark.id, kind: .bookmark),
        ])

        #expect(pushed == 1)
        let cleaned = await metadata.cleanIds()
        #expect(cleaned == [bookmark.id])
        let cleanKinds = await metadata.cleanKinds()
        #expect(cleanKinds == [.bookmark])
        let forgotten = await metadata.forgetIds()
        #expect(forgotten.isEmpty)
    }

    @Test("Empty input -> 0 pushed, no HTTP call")
    func emptyInputNoOp() async throws {
        BookmarkUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubBookmarkStore()
        let uploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: store,
            metadataStore: metadata
        )

        BookmarkUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }
        let pushed = try await uploader.pushPending(items: [])
        #expect(pushed == 0)
        #expect(BookmarkUploaderMockURLProtocol.capturedSnapshot().isEmpty)
    }

    @Test("Missing local row -> tombstone (deleted=true) in body + metadata.forget(.bookmark)")
    func missingRowTombstones() async throws {
        BookmarkUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubBookmarkStore()
        let uploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: store,
            metadataStore: metadata
        )

        let missingId = UUID()
        let acceptedAtRef = acceptedAtUnix - 978_307_200
        let bodyBox = OSAllocatedUnfairLock<Data?>(initialState: nil)

        BookmarkUploaderMockURLProtocol.handler = { request in
            let captured: Data? = {
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buf = Data()
                    let bufSize = 1024
                    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { bytes.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(bytes, maxLength: bufSize)
                        if read <= 0 { break }
                        buf.append(bytes, count: read)
                    }
                    return buf
                } else if let body = request.httpBody {
                    return body
                }
                return nil
            }()
            bodyBox.withLock { $0 = captured }
            let respBody = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(respBody.utf8), nil)
        }

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: missingId, kind: .bookmark),
        ])

        #expect(pushed == 1)
        let forgotten = await metadata.forgetIds()
        #expect(forgotten == [missingId])
        let forgetKinds = await metadata.forgetKinds()
        #expect(forgetKinds == [.bookmark])
        let cleaned = await metadata.cleanIds()
        #expect(cleaned.isEmpty)

        let body = bodyBox.withLock { $0 }
        #expect(body != nil)
        if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let changes = json["changes"] as? [[String: Any]] {
            #expect(changes.count == 1)
            #expect(changes[0]["deleted"] as? Bool == true)
            #expect(changes[0]["kind"] as? String == "bookmark")
        } else {
            Issue.record("Failed to parse push body as JSON")
        }
    }

    @Test("Live push body carries kind=bookmark + snake_case payload (locator/book_id)")
    func livePushWireShape() async throws {
        BookmarkUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubBookmarkStore()

        let bookmark = Bookmark(
            bookId: UUID(),
            locator: "pdf-v1:page:7",
            label: nil,
            snippet: "snip",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([bookmark])

        let acceptedAtRef = acceptedAtUnix - 978_307_200
        let bodyBox = OSAllocatedUnfairLock<Data?>(initialState: nil)
        BookmarkUploaderMockURLProtocol.handler = { request in
            let captured: Data? = {
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buf = Data()
                    let bufSize = 2048
                    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { bytes.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(bytes, maxLength: bufSize)
                        if read <= 0 { break }
                        buf.append(bytes, count: read)
                    }
                    return buf
                }
                return request.httpBody
            }()
            bodyBox.withLock { $0 = captured }
            return (200, Data("{ \"accepted_at\": \(acceptedAtRef) }".utf8), nil)
        }

        let uploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: store,
            metadataStore: metadata
        )
        _ = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: bookmark.id, kind: .bookmark),
        ])

        let body = try #require(bodyBox.withLock { $0 })
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let changes = try #require(json["changes"] as? [[String: Any]])
        #expect(changes.count == 1)
        #expect(changes[0]["kind"] as? String == "bookmark")
        #expect(changes[0]["deleted"] as? Bool == false)
        // The nested payload uses the canonical snake_case keys.
        let payload = try #require(changes[0]["payload"] as? [String: Any])
        #expect(payload["book_id"] != nil)
        #expect(payload["locator"] as? String == "pdf-v1:page:7")
        #expect(payload["snippet"] as? String == "snip")
        #expect(payload["created_at"] is String)
    }

    @Test("Mixed live + tombstone batch: markClean + forget split correctly")
    func mixedBatch() async throws {
        BookmarkUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubBookmarkStore()

        let liveBookmark = Bookmark(
            bookId: UUID(),
            locator: "epub-v1:cfi",
            snippet: "live"
        )
        let tombstonedId = UUID()
        await store.seed([liveBookmark])

        let acceptedAtRef = acceptedAtUnix - 978_307_200
        BookmarkUploaderMockURLProtocol.handler = { _ in
            let body = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(body.utf8), nil)
        }

        let uploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: liveBookmark.id, kind: .bookmark),
            SyncQueueItem(entityId: tombstonedId, kind: .bookmark),
        ])

        #expect(pushed == 2)
        let cleaned = await metadata.cleanIds()
        let forgotten = await metadata.forgetIds()
        #expect(cleaned == [liveBookmark.id])
        #expect(forgotten == [tombstonedId])
    }
}
