import Testing
import Foundation
@testable import RishiSync
import RishiAPI
import RishiCore

/// SYNC-01 (highlights) — HighlightUploader: drain pending highlights → POST → markClean / forget.
@Suite("HighlightUploader", .serialized)
struct HighlightUploaderTests {

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
        func forgetIds() -> [UUID] { forgetCalls.map(\.0) }
    }

    private actor StubHighlightStore: HighlightStore {
        private var rows: [HighlightID: Highlight] = [:]

        func seed(_ rows: [Highlight]) { for r in rows { self.rows[r.id] = r } }
        func highlights(for bookId: BookID) async throws -> [Highlight] {
            rows.values.filter { $0.bookId == bookId }
        }
        func highlight(_ id: HighlightID) async throws -> Highlight? { rows[id] }
        func upsert(_ highlight: Highlight) async throws { rows[highlight.id] = highlight }
        func delete(_ id: HighlightID) async throws { rows[id] = nil }
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    // accepted_at on the wire is a Foundation Date (seconds since reference date).
    private let acceptedAtUnix: TimeInterval = 1_780_000_000

    // MARK: - Tests

    @Test("Happy path: one pending highlight → POST /api/sync/push → markClean")
    func happyPath() async throws {
        MockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubHighlightStore()

        let highlight = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .yellow,
            text: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([highlight])

        let acceptedAtRef = acceptedAtUnix - 978_307_200
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sync/push")
            let body = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(body.utf8), nil)
        }

        let uploader = HighlightUploader(
            workerClient: workerClient,
            highlightStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: highlight.id, kind: .highlight),
        ])

        #expect(pushed == 1)
        let cleaned = await metadata.cleanIds()
        #expect(cleaned == [highlight.id])
        let forgotten = await metadata.forgetIds()
        #expect(forgotten.isEmpty)
    }

    @Test("Empty input → 0 pushed, no HTTP call")
    func emptyInputNoOp() async throws {
        MockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubHighlightStore()
        let uploader = HighlightUploader(
            workerClient: workerClient,
            highlightStore: store,
            metadataStore: metadata
        )

        MockURLProtocol.handler = { _ in (500, Data(), nil) }
        let pushed = try await uploader.pushPending(items: [])
        #expect(pushed == 0)
        #expect(MockURLProtocol.capturedSnapshot().isEmpty)
    }

    @Test("Missing local row → tombstone (deleted=true) in body + metadata.forget")
    func missingRowTombstones() async throws {
        MockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubHighlightStore()
        let uploader = HighlightUploader(
            workerClient: workerClient,
            highlightStore: store,
            metadataStore: metadata
        )

        let missingId = UUID()
        let acceptedAtRef = acceptedAtUnix - 978_307_200

        // Capture the request body to verify the tombstone shape.
        nonisolated(unsafe) var capturedBody: Data?
        let bodyLock = NSLock()

        MockURLProtocol.handler = { request in
            // URLProtocol doesn't populate request.httpBody — read from BodyStream.
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
                bodyLock.lock(); capturedBody = buf; bodyLock.unlock()
            } else if let body = request.httpBody {
                bodyLock.lock(); capturedBody = body; bodyLock.unlock()
            }
            let respBody = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(respBody.utf8), nil)
        }

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: missingId, kind: .highlight),
        ])

        #expect(pushed == 1)
        let forgotten = await metadata.forgetIds()
        #expect(forgotten == [missingId])
        let cleaned = await metadata.cleanIds()
        #expect(cleaned.isEmpty)

        // Verify the body carried a tombstone for the missing id.
        bodyLock.lock(); let body = capturedBody; bodyLock.unlock()
        #expect(body != nil)
        if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let changes = json["changes"] as? [[String: Any]] {
            #expect(changes.count == 1)
            #expect(changes[0]["deleted"] as? Bool == true)
            #expect(changes[0]["kind"] as? String == "highlight")
        } else {
            Issue.record("Failed to parse push body as JSON")
        }
    }

    @Test("Mixed live + tombstone batch: both kinds present, markClean + forget split correctly")
    func mixedBatch() async throws {
        MockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubHighlightStore()

        let liveHighlight = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .green,
            text: "live"
        )
        let tombstonedId = UUID()
        await store.seed([liveHighlight])

        let acceptedAtRef = acceptedAtUnix - 978_307_200
        MockURLProtocol.handler = { _ in
            let body = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(body.utf8), nil)
        }

        let uploader = HighlightUploader(
            workerClient: workerClient,
            highlightStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: liveHighlight.id, kind: .highlight),
            SyncQueueItem(entityId: tombstonedId, kind: .highlight),
        ])

        #expect(pushed == 2)
        let cleaned = await metadata.cleanIds()
        let forgotten = await metadata.forgetIds()
        #expect(cleaned == [liveHighlight.id])
        #expect(forgotten == [tombstonedId])
    }
}
