@testable import rishi
import Testing
import Foundation
import CryptoKit
import SwiftData


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
        var operationIds: [String: UUID] = [:]

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
        func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID {
            let key = "\(kind.rawValue):\(entityId.uuidString)"
            if let existing = operationIds[key] { return existing }
            let created = UUID()
            operationIds[key] = created
            return created
        }
        func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID? {
            operationIds["\(kind.rawValue):\(entityId.uuidString)"]
        }

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

    private actor AcceptancePersistenceProbe {
        private(set) var calls = 0

        func persist() -> Bool {
            calls += 1
            return false
        }
    }

    private actor AcceptanceProbe {
        private(set) var permit: BookReadingPermit?
        private(set) var fingerprint: BookFileFingerprint?
        private(set) var persistenceError: String?
        func capture(permit: BookReadingPermit, fingerprint: BookFileFingerprint) {
            self.permit = permit
            self.fingerprint = fingerprint
        }
        func capturePersistenceError(_ error: String) { persistenceError = error }
    }

    /// URLProtocol callbacks are synchronous, so use bounded semaphores at the
    /// network boundary and always release the response from test cleanup.
    private final class DelayedPushGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let releaseResponse = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var wasReleased = false

        func holdResponse() {
            entered.signal()
            _ = releaseResponse.wait(timeout: .now() + 5)
        }

        func waitForPushOrCompletion(completion: DispatchSemaphore) -> (reachedPush: Bool, completedEarly: Bool) {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if entered.wait(timeout: .now()) == .success { return (true, false) }
                if completion.wait(timeout: .now()) == .success { return (false, true) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return (false, false)
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !wasReleased else { return }
            wasReleased = true
            releaseResponse.signal()
        }
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

    private func readySourceProvider(storage: BookFileStorage) -> @Sendable (Book) async throws -> BookUploadSource? {
        { book in
            let attrs = try FileManager.default.attributesOfItem(atPath: storage.absoluteFileURL(for: book).path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs[.modificationDate] as? Date ?? .distantPast
            return BookUploadSource(
                url: storage.absoluteFileURL(for: book),
                fingerprint: BookFileFingerprint(
                    bookID: book.id,
                    ownerID: book.userId,
                    sha256: "42e3cfce7d573fcbf45639d69ab08edd30db630fadac24c85813f3230ec4978c",
                    version: ManagedFileVersion(byteCount: size, modificationDate: modified, fileIdentifier: nil, materializationRevision: UUID())
                ),
                readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 1, bookID: book.id, contentRevision: UUID())
            )
        }
    }

    private func makeSession(requestTimeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.protocolClasses = [BookUploaderMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeAuthorizedUploadFixture() async throws -> (
        BookFileStorage, URL, Book, SwiftDataBookImportPersistence, BookFileFingerprint, BookReadingPermit
    ) {
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let managedURL = storage.absoluteFileURL(for: book)
        let bytes = try Data(contentsOf: managedURL)
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: digest, version: version)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: 1)
        try await persistence.setBookReadingAuthorization(
            bookID: book.id, ownerID: book.userId, generation: 1,
            contentRevision: revision, tombstoned: false
        )
        #expect(try await persistence.cacheManagedFingerprint(
            fingerprint, expectedGeneration: 1, expectedRelativePath: book.fileURL, expectedVersion: version
        ))
        let permit = try #require(try await persistence.readingPermit(
            forManagedFingerprint: fingerprint, expectedRelativePath: book.fileURL, generation: 1
        ))
        return (storage, root, book, persistence, fingerprint, permit)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
    }

    private func body(of request: URLRequest) -> Data? {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 2_048
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Tests

    @Test("Pending or unverified books are rejected before any upload request")
    func missingManagedSourceDoesNotReachNetwork() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let uploader = BookUploader(
            workerClient: makeWorkerClient(session: session),
            metadataStore: StubMetadata(),
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "test-user" }
        )

        await #expect(throws: BookUploader.UploadError.self) {
            try await uploader.upload(book)
        }
        #expect(BookUploaderMockURLProtocol.capturedSnapshot().isEmpty)
    }

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
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: readySourceProvider(storage: storage),
            persistServerAcceptance: { _, _, _ in true }
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
                return (200, Data("{\"accepted_at\": 946684800,\"accepted\":true}".utf8), nil)
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
        let pushed = try #require(body(of: captured[2]))
        let pushJSON = try #require(try JSONSerialization.jsonObject(with: pushed) as? [String: Any])
        let changes = try #require(pushJSON["changes"] as? [[String: Any]])
        let payload = try #require(changes.first?["payload"] as? [String: Any])
        #expect(changes.first?["kind"] as? String == "book")
        #expect(changes.first?["operation_id"] as? String != nil)
        #expect(payload["file_url"] == nil)
        #expect(payload["file_r2_key"] as? String == BookUploader.r2Key(for: book, userId: "001234.abcdef0123456789.1234"))
        #expect(payload["file_hash"] as? String == "42e3cfce7d573fcbf45639d69ab08edd30db630fadac24c85813f3230ec4978c")
        #expect(payload["file_size"] as? Int == 10)

        // markClean called exactly once with .book kind + remote ETag.
        let calls = await metadata.calls()
        #expect(calls.count == 1)
        #expect(calls.first?.0 == book.id)
        #expect(calls.first?.1 == .book)
        #expect(calls.first?.2 == Date(timeIntervalSinceReferenceDate: 946684800))
        #expect(calls.first?.3 == "\"abc123\"")
    }

    @Test("Failed server-acceptance persistence keeps the book dirty")
    func failedAcceptancePersistenceDoesNotMarkClean() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let persistence = AcceptancePersistenceProbe()
        let (storage, root) = try await makeFileStorage()
        let book = try makeBookOnDisk(in: root)
        let uploader = BookUploader(
            workerClient: workerClient,
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: readySourceProvider(storage: storage),
            persistServerAcceptance: { _, _, _ in await persistence.persist() }
        )

        let presignedURL = "https://r2.example.invalid/books/acceptance-failure.epub?sig=abc"
        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/upload-url" {
                return (200, Data("{\"url\":\"\(presignedURL)\",\"expires_at\":946684800}".utf8), nil)
            }
            if request.url?.absoluteString == presignedURL {
                return (200, Data(), ["ETag": "\"abc123\""])
            }
            if request.url?.path == "/api/sync/push" {
                return (200, Data("{\"accepted_at\":946684800,\"accepted\":true}".utf8), nil)
            }
            return (404, Data(), nil)
        }

        await #expect(throws: BookUploader.UploadError.self) {
            try await uploader.upload(book)
        }
        #expect(await persistence.calls == 1)
        #expect(await metadata.calls().isEmpty)
    }

    @Test("same-owner relogin cannot accept a delayed upload from the prior generation")
    func delayedAcceptanceAfterSameOwnerReloginIsRejected() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession(requestTimeout: 8)
        let (storage, _, book, persistence, fingerprint, originalPermit) = try await makeAuthorizedUploadFixture()
        let metadata = try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        try await metadata.markDirty(entityId: book.id, kind: .book)
        let gate = DelayedPushGate()
        let acceptance = AcceptanceProbe()
        let uploader = BookUploader(
            workerClient: makeWorkerClient(session: session),
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: { requestedBook in
                let currentFingerprint = try #require(try await persistence.fingerprint(bookID: requestedBook.id, ownerID: requestedBook.userId))
                let currentPermit = try #require(try await persistence.readingPermit(
                    forManagedFingerprint: currentFingerprint, expectedRelativePath: requestedBook.fileURL, generation: 1
                ))
                return BookUploadSource(url: storage.absoluteFileURL(for: requestedBook), fingerprint: currentFingerprint, readingPermit: currentPermit)
            },
            persistServerAcceptance: { permit, expectedFingerprint, accepted in
                await acceptance.capture(permit: permit, fingerprint: expectedFingerprint)
                do {
                    return try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: expectedFingerprint, acceptance: accepted)
                } catch {
                    await acceptance.capturePersistenceError(String(describing: error))
                    return false
                }
            }
        )
        let presignedURL = "https://r2.example.invalid/books/delayed.epub?sig=held"
        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/upload-url" {
                return (200, Data("{\"url\":\"\(presignedURL)\",\"expires_at\":946684800}".utf8), nil)
            }
            if request.url?.absoluteString == presignedURL { return (200, Data(), nil) }
            if request.url?.path == "/api/sync/push" {
                gate.holdResponse()
                return (200, Data("{\"accepted_at\":946684800,\"accepted\":true}".utf8), nil)
            }
            return (404, Data(), nil)
        }

        let completed = DispatchSemaphore(value: 0)
        let upload = Task {
            defer { completed.signal() }
            try await uploader.upload(book)
        }
        defer { gate.release() }
        let gateResult = gate.waitForPushOrCompletion(completion: completed)
        let reachedPush = gateResult.reachedPush
        #expect(reachedPush, gateResult.completedEarly
            ? "upload completed before reaching the held server-acceptance response"
            : "upload should reach the held server-acceptance response before the bounded wait expires")
        if reachedPush {
            // Reauthorize the same owner under a fresh session generation while
            // the server's accepted response is still in flight.
            try await persistence.setAccountAuthorization(ownerID: book.userId, generation: 2)
            try await persistence.setBookReadingAuthorization(
                bookID: book.id, ownerID: book.userId, generation: 2,
                contentRevision: originalPermit.contentRevision, tombstoned: false
            )
        }
        gate.release()
        await #expect(throws: BookUploader.UploadError.self) { try await upload.value }
        #expect(await acceptance.permit == originalPermit)
        #expect(await acceptance.fingerprint == fingerprint)
        #expect(await acceptance.persistenceError == nil)
        #expect(try await metadata.pending(kind: .book, limit: 10) == [SyncPendingItem(entityId: book.id, kind: .book)])
    }

    @Test("content replacement cannot accept a delayed upload of the previous bytes")
    func delayedAcceptanceAfterContentReplacementIsRejected() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession(requestTimeout: 8)
        let (storage, _, book, persistence, fingerprint, originalPermit) = try await makeAuthorizedUploadFixture()
        let metadata = try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        try await metadata.markDirty(entityId: book.id, kind: .book)
        let gate = DelayedPushGate()
        let acceptance = AcceptanceProbe()
        let uploader = BookUploader(
            workerClient: makeWorkerClient(session: session),
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: { requestedBook in
                let currentFingerprint = try #require(try await persistence.fingerprint(bookID: requestedBook.id, ownerID: requestedBook.userId))
                let currentPermit = try #require(try await persistence.readingPermit(
                    forManagedFingerprint: currentFingerprint, expectedRelativePath: requestedBook.fileURL, generation: 1
                ))
                return BookUploadSource(url: storage.absoluteFileURL(for: requestedBook), fingerprint: currentFingerprint, readingPermit: currentPermit)
            },
            persistServerAcceptance: { permit, expectedFingerprint, accepted in
                await acceptance.capture(permit: permit, fingerprint: expectedFingerprint)
                do {
                    return try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: expectedFingerprint, acceptance: accepted)
                } catch {
                    await acceptance.capturePersistenceError(String(describing: error))
                    return false
                }
            }
        )
        let presignedURL = "https://r2.example.invalid/books/replaced.epub?sig=held"
        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/upload-url" {
                return (200, Data("{\"url\":\"\(presignedURL)\",\"expires_at\":946684800}".utf8), nil)
            }
            if request.url?.absoluteString == presignedURL { return (200, Data(), nil) }
            if request.url?.path == "/api/sync/push" {
                gate.holdResponse()
                return (200, Data("{\"accepted_at\":946684800,\"accepted\":true}".utf8), nil)
            }
            return (404, Data(), nil)
        }

        let completed = DispatchSemaphore(value: 0)
        let upload = Task {
            defer { completed.signal() }
            try await uploader.upload(book)
        }
        defer { gate.release() }
        let gateResult = gate.waitForPushOrCompletion(completion: completed)
        let reachedPush = gateResult.reachedPush
        #expect(reachedPush, gateResult.completedEarly
            ? "upload completed before reaching the held server-acceptance response"
            : "upload should reach the held server-acceptance response before the bounded wait expires")
        if reachedPush {
            // Replace the exact managed file and atomically publish its new
            // fingerprint and canonical reading revision before releasing ack.
            let managedURL = storage.absoluteFileURL(for: book)
            let replacementBytes = Data("replacement EPUB bytes".utf8)
            try replacementBytes.write(to: managedURL, options: .atomic)
            let revision = UUID()
            try await persistence.setBookReadingAuthorization(
                bookID: book.id, ownerID: book.userId, generation: 1,
                contentRevision: revision, tombstoned: false
            )
            let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: revision))
            let digest = SHA256.hash(data: replacementBytes).map { String(format: "%02x", $0) }.joined()
            let replacementFingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: digest, version: version)
            #expect(try await persistence.cacheManagedFingerprint(
                replacementFingerprint, expectedGeneration: 1, expectedRelativePath: book.fileURL, expectedVersion: version
            ))
        }
        gate.release()
        await #expect(throws: BookUploader.UploadError.self) { try await upload.value }
        #expect(await acceptance.permit == originalPermit)
        #expect(await acceptance.fingerprint == fingerprint)
        #expect(await acceptance.persistenceError == nil)
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId)?.sha256 != fingerprint.sha256)
        #expect(try await metadata.pending(kind: .book, limit: 10) == [SyncPendingItem(entityId: book.id, kind: .book)])
    }

    @Test("Stale server acknowledgement does NOT markClean")
    func staleServerAcknowledgementDoesNotMarkClean() async throws {
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
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: readySourceProvider(storage: storage)
        )

        let presignedURL = "https://r2.example.invalid/books/\(book.id.uuidString).epub?sig=stale"
        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/upload-url" {
                return (200, Data("{\"url\":\"\(presignedURL)\",\"expires_at\":946684800}".utf8), nil)
            }
            if request.url?.absoluteString == presignedURL {
                return (200, Data(), nil)
            }
            if request.url?.path == "/api/sync/push" {
                return (200, Data("{\"accepted_at\":946684800,\"accepted\":false}".utf8), nil)
            }
            return (404, Data(), nil)
        }

        await #expect(throws: BookUploader.UploadError.self) {
            try await uploader.upload(book)
        }
        let calls = await metadata.calls()
        #expect(calls.isEmpty)
    }

    @Test("Stale tombstone acknowledgement does NOT markClean")
    func staleTombstoneAcknowledgementDoesNotMarkClean() async throws {
        BookUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let uploader = BookUploader(
            workerClient: workerClient,
            metadataStore: metadata,
            fileStorage: storage,
            urlSession: session,
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: readySourceProvider(storage: storage)
        )

        BookUploaderMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/push" {
                return (200, Data("{\"accepted_at\":946684800,\"accepted\":false}".utf8), nil)
            }
            return (404, Data(), nil)
        }

        await #expect(throws: BookUploader.UploadError.self) {
            try await uploader.uploadTombstone(UUID())
        }
        let calls = await metadata.calls()
        #expect(calls.isEmpty)
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
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: readySourceProvider(storage: storage)
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
            userIdProvider: { "001234.abcdef0123456789.1234" },
            managedSourceProvider: readySourceProvider(storage: storage)
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
