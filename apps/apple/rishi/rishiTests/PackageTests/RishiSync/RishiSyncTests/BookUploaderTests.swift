@testable import rishi
import Testing
import Foundation





/// SYNC-01 — BookUploader: presigned URL → PUT to R2 → markClean.
///
/// `.serialized` because MockURLProtocol uses nonisolated(unsafe) static
/// state that would race across parallel @Test methods.
@Suite("BookUploader", .serialized)
struct BookUploaderTests {

    // MARK: - Stubs

    /// In-memory metadata stub recording markClean calls for assertions.
    private actor StubMetadata: SyncMetadataStore {
        var cleanCalls: [(UUID, SyncEntityKind, Date, String?)] = []

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
        }
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {}

        func calls() -> [(UUID, SyncEntityKind, Date, String?)] { cleanCalls }
    }

    /// In-memory BookStore stub — BookFileStorage requires one for its
    /// initializer even though BookUploader only reads bytes off disk.
    private actor StubBookStore: BookStore {
        private var rows: [BookID: Book] = [:]
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
    }

    // MARK: - Fixtures

    private func makeFileStorage() async throws -> (BookFileStorage, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookFileStorage(rootURL: root, bookStore: StubBookStore(), coverExtractors: [:])
        return (storage, root)
    }

    private func makeBookOnDisk(in root: URL) throws -> Book {
        let bookId = UUID()
        let relPath = "Books/\(bookId.uuidString)/test.epub"
        let book = Book(
            id: bookId,
            userId: UUID(),
            title: "Test",
            formatType: .epub,
            fileURL: relPath
        )
        let absURL = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: absURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("EPUB BYTES".utf8).write(to: absURL)
        return book
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BookUploaderMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    // MARK: - Tests

    @Test("Happy path: R2 bytes → separate book metadata push → markClean")
    func happyPath() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let uploader = BookUploader(
            workerClient: workerClient,
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" }
        )

        let presignedURL = "https://r2.example.invalid/books/\(book.userId.uuidString)/\(book.id.uuidString).epub?sig=abc"

        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/upload-url" {
                // expires_at is a Foundation Date wire value (seconds since reference date) —
                // WorkerClient decodes with the default JSONDecoder strategy.
                let body = """
                { "url": "\(presignedURL)", "expires_at": 946684800 }
                """
                return (200, Data(body.utf8), nil)
            }
            if request.url?.absoluteString == presignedURL {
                return (200, Data(), ["ETag": "\"abc123\""])
            }
            if request.url?.path == "/api/sync/push" {
                return (200, Data("{\"accepted_at\": 946684800}".utf8), nil)
            }
            return (404, Data(), nil)
        }

        try await uploader.upload(book)

        // Two HTTP calls: presign POST + R2 PUT.
        let captured = BookUploaderMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 3)
        #expect(captured[0].url?.path == "/api/sync/upload-url")
        #expect(captured[0].httpMethod == "POST")
        #expect(captured[1].httpMethod == "PUT")
        #expect(captured[1].url?.absoluteString == presignedURL)
        #expect(captured[2].url?.path == "/api/sync/push")
        let pushed = try #require(captured[2].httpBody)
        let pushJSON = try #require(try JSONSerialization.jsonObject(with: pushed) as? [String: Any])
        let changes = try #require(pushJSON["changes"] as? [[String: Any]])
        let payload = try #require(changes.first?["payload"] as? [String: Any])
        #expect(changes.first?["kind"] as? String == "book")
        #expect(payload["file_url"] == nil)
        #expect(payload["file_r2_key"] as? String == BookUploader.r2Key(for: book, userId: "001234.abcdef0123456789.1234"))

        // markClean called exactly once with .book kind + remote ETag.
        let calls = await metadata.calls()
        #expect(calls.count == 1)
        #expect(calls.first?.0 == book.id)
        #expect(calls.first?.1 == .book)
        #expect(calls.first?.3 == "\"abc123\"")
    }

    @Test("Presigned-URL request failure (500) does NOT markClean")
    func presignedFailureDoesNotMarkClean() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let uploader = BookUploader(
            workerClient: workerClient,
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" }
        )

        // Worker returns 500 on the presign call.
        BookUploaderMockURLProtocol.handler = { _ in
            return (500, Data("{}".utf8), nil)
        }

        await #expect(throws: (any Error).self) {
            try await uploader.upload(book)
        }
        let calls = await metadata.calls()
        #expect(calls.isEmpty)
    }

    @Test("PUT failure (R2 503) does NOT markClean")
    func r2PutFailureDoesNotMarkClean() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let uploader = BookUploader(
            workerClient: workerClient,
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" }
        )

        let presignedURL = "https://r2.example.invalid/books/x.epub?sig=abc"
        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/upload-url" {
                let body = """
                { "url": "\(presignedURL)", "expires_at": 946684800 }
                """
                return (200, Data(body.utf8), nil)
            }
            return (503, Data(), nil)
        }

        await #expect(throws: BookUploader.UploadError.self) {
            try await uploader.upload(book)
        }
        let calls = await metadata.calls()
        #expect(calls.isEmpty)
    }

    @Test("Upload with no signed-in user throws and does not markClean")
    func noUserThrows() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let uploader = BookUploader(
            workerClient: workerClient,
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { nil }
        )
        await #expect(throws: BookUploader.UploadError.self) {
            try await uploader.upload(book)
        }
        let calls = await metadata.calls()
        #expect(calls.isEmpty)
    }

    @Test("R2 key uses the raw session userId verbatim, not the book's UUID")
    func r2KeyUsesRawSessionUserId() {
        let bookId = UUID()
        let book = Book(id: bookId, userId: UUID(), title: "T", formatType: .pdf, fileURL: "x")
        // Better Auth ids are non-UUID strings (e.g. Apple sub or 32-char id).
        let rawUserId = "001234.abcdef0123456789.1234"
        let key = BookUploader.r2Key(for: book, userId: rawUserId)
        #expect(key == "books/\(rawUserId)/\(bookId.uuidString).pdf")
    }

    @Test("Content-Type matches BookFormat")
    func contentTypePerFormat() {
        #expect(BookUploader.contentType(for: .epub) == "application/epub+zip")
        #expect(BookUploader.contentType(for: .pdf) == "application/pdf")
        #expect(BookUploader.contentType(for: .mobi) == "application/x-mobipocket-ebook")
        #expect(BookUploader.contentType(for: .azw3) == "application/vnd.amazon.ebook")
    }
}
