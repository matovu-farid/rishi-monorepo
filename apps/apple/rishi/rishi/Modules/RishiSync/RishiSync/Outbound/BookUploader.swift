import Foundation





/// Uploads a single Book's file bytes to R2 via the presigned-URL handshake.
///
/// SYNC-01: New books upload to R2 via /api/sync/upload-url after import.
///
/// Wire pattern:
///   1. POST /api/sync/upload-url { key, content_type } → { url, expires_at }
///   2. PUT <url> (raw bytes; Content-Type matches)
    ///   3. POST /api/sync/push { kind: "book", payload: metadata }
    ///   4. SyncMetadataStore.markClean(bookId, .book, now, etag)
///
/// Errors at step 1 or 2 leave the row dirty so the next sync wave retries.
/// The uploader does NOT touch SyncQueue — `SyncEngine` (07-04) is the only
/// consumer of the queue; this class is a single-shot pure async function.
public final class BookUploader: Sendable {

    public enum UploadError: Error, Sendable {
        case bytesUnreadable(URL)
        case presignedRequestFailed(String)
        case uploadFailed(status: Int)
        case serverRejected
    }

    private let workerClient: WorkerClient
    private let metadataStore: any SyncMetadataStore
    private let fileStorage: BookFileStorage
    private let urlSession: URLSession
    private let userIdProvider: @Sendable () async -> String?

    public init(
        workerClient: WorkerClient,
        metadataStore: any SyncMetadataStore,
        fileStorage: BookFileStorage,
        urlSession: URLSession = .shared,
        userIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.workerClient = workerClient
        self.metadataStore = metadataStore
        self.fileStorage = fileStorage
        self.urlSession = urlSession
        self.userIdProvider = userIdProvider
    }

    /// Upload a single book's bytes. Throws on any failure (without marking
    /// the metadata row clean) so the engine retries on the next wave.
    public func upload(_ book: Book) async throws {
        guard let ownerId = await userIdProvider() else {
            throw UploadError.presignedRequestFailed("missing session user id")
        }
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: book.id, kind: .book)
        let operationId = try await metadataStore.ensureOperationId(entityId: book.id, kind: .book)
        let key = Self.r2Key(for: book, userId: ownerId)
        let contentType = Self.contentType(for: book.formatType)

        // 1. Request a presigned PUT URL from the worker.
        let presigned: PresignedURLResponse
        do {
            presigned = try await workerClient.send(
                SyncUploadURLEndpoint(body: .init(key: key, contentType: contentType))
            )
        } catch {
            Log.error("sync.book.presign.failed", error: error)
            throw UploadError.presignedRequestFailed(String(describing: error))
        }

        guard let putURL = URL(string: presigned.url) else {
            throw UploadError.presignedRequestFailed("malformed presigned URL")
        }

        // 2. Read the bytes off disk.
        let absoluteFileURL = fileStorage.absoluteFileURL(for: book)
        let data: Data
        do {
            data = try Data(contentsOf: absoluteFileURL)
        } catch {
            throw UploadError.bytesUnreadable(absoluteFileURL)
        }

        // 3. PUT to R2.
        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        Log.event("sync.book.upload.started", level: .info, data: [
            "book_id": book.id.uuidString,
            "bytes": String(data.count),
        ])
        let (responseBody, putResponse) = try await urlSession.upload(for: request, from: data)
        guard let http = putResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (putResponse as? HTTPURLResponse)?.statusCode ?? -1
            // R2 returns an S3-style XML body (<Error><Code>...</Code>...) on
            // rejection — surface it so PUT failures are diagnosable.
            let r2Error = String(decoding: responseBody, as: UTF8.self)
            Log.event("sync.book.upload.failed", level: .error, data: [
                "book_id": book.id.uuidString,
                "status": String(status),
                "r2_error": String(r2Error.prefix(500)),
            ])
            throw UploadError.uploadFailed(status: status)
        }

        // Persist metadata only after the bytes are safely in R2. This makes a
        // pulled book downloadable as soon as its D1 row becomes visible.
        let response: SyncPushResponse
        do {
            let payload = try SyncPayloadCodec.encodeBook(book, r2Key: key)
            response = try await workerClient.send(
                SyncPushEndpoint(body: .init(changes: [SyncChange(
                    kind: SyncEntityKind.book.rawValue,
                    id: book.id,
                    operationId: operationId,
                    payload: payload,
                    updatedAt: expectedDirtyAt ?? Date(),
                    deleted: false
                )]))
            )
            guard response.accepted != false else {
                Log.event("sync.book.metadata.push.rejected", level: .error, data: [
                    "book_id": book.id.uuidString,
                    "reason": "stale",
                ])
                throw UploadError.serverRejected
            }
        } catch {
            if case UploadError.serverRejected = error { throw error }
            Log.error("sync.book.metadata.push.failed", error: error)
            throw UploadError.presignedRequestFailed("metadata push failed: \(error)")
        }

        // 4. markClean with the server's ETag for future change-detection.
        let etag = http.value(forHTTPHeaderField: "ETag")
        guard try await metadataStore.markCleanIfCurrent(
            entityId: book.id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            expectedOperationId: operationId,
            lastSyncedAt: response.acceptedAt,
            remoteEtag: etag
        ) else {
            throw UploadError.presignedRequestFailed("local book changed during upload")
        }
        Log.event("sync.book.upload.completed", level: .info, data: [
            "book_id": book.id.uuidString,
        ])
    }

    /// Pushes a metadata-only deletion for a book whose local row/file has
    /// already been removed. The worker keeps the remote tombstone so other
    /// devices converge on the deletion.
    public func uploadTombstone(_ id: BookID) async throws {
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: id, kind: .book)
        let operationId = try await metadataStore.ensureOperationId(entityId: id, kind: .book)
        let response = try await workerClient.send(
            SyncPushEndpoint(body: .init(changes: [SyncChange(
                kind: SyncEntityKind.book.rawValue,
                id: id,
                operationId: operationId,
                payload: SyncOpaqueJSON(data: Data("{}".utf8)),
                updatedAt: expectedDirtyAt ?? Date(),
                deleted: true
            )]))
        )
        guard response.accepted != false else { throw UploadError.serverRejected }
        guard try await metadataStore.acknowledgeTombstoneIfCurrent(
            entityId: id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            expectedOperationId: operationId,
            lastSyncedAt: response.acceptedAt,
            remoteEtag: nil
        ) else {
            throw UploadError.presignedRequestFailed("local book deletion changed during upload")
        }
    }

    // MARK: - Helpers

    /// R2 object key for a book file. Pinned by the worker contract:
    /// `books/<userId>/<bookId>.<ext>`, where `userId` is the raw worker
    /// session user id string (Better Auth `user.id`), not the book's
    /// derived UUID.
    static func r2Key(for book: Book, userId: String) -> String {
        let ext = book.formatType.rawValue
        return "books/\(userId)/\(book.id.uuidString).\(ext)"
    }

    /// Content-Type header value for the R2 PUT. Worker's bucket policy keys
    /// off this header for cache-control rules.
    static func contentType(for format: BookFormat) -> String {
        switch format {
        case .epub: return "application/epub+zip"
        case .pdf:  return "application/pdf"
        case .mobi: return "application/x-mobipocket-ebook"
        case .azw3: return "application/vnd.amazon.ebook"
        }
    }
}
