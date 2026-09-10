import CryptoKit
import Foundation



struct BookImporter: Sendable {
    private static let importGate = BookImportGate()

    private let rootURL: URL
    private let booksDirURL: URL
    private let bookStore: any BookStore
    private let coverExtractors: [String: any CoverExtractor]
    private let metadataExtractors: [String: any MetadataExtractor]
    private let bookIndexingHook: any BookIndexingHook
    private let isTombstoned: (@Sendable (BookID) async -> Bool)?

    private var fileManager: FileManager { .default }

    init(
        rootURL: URL,
        booksDirURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor],
        bookIndexingHook: any BookIndexingHook,
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil
    ) {
        self.rootURL = rootURL
        self.booksDirURL = booksDirURL
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.bookIndexingHook = bookIndexingHook
        self.isTombstoned = isTombstoned
    }

    func importBook(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String? = nil
    ) async throws -> Book {
        await Self.importGate.acquire()
        do {
            let book = try await importBookWhileHoldingGate(
                from: sourceURL,
                ownerId: ownerId,
                expectedContentHash: expectedContentHash
            )
            await Self.importGate.release()
            return book
        } catch {
            await Self.importGate.release()
            throw error
        }
    }

    private func importBookWhileHoldingGate(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String?
    ) async throws -> Book {
        try ensureBooksDirExists()

        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat(rawValue: ext) else {
            throw BookFileStorage.StorageError.unsupportedFormat(ext: ext)
        }

        let contentHash: String
        do {
            contentHash = try expectedContentHash ?? Self.sha256(fileURL: sourceURL)
        } catch {
            Log.error("library.import.hash.failed", error: error)
            throw BookFileStorage.StorageError.sourceUnreadable
        }

        let existingBooks = try await bookStore.books(for: ownerId)
        for existing in existingBooks {
            let existingURL = rootURL.appendingPathComponent(existing.fileURL)
            guard fileManager.fileExists(atPath: existingURL.path) else { continue }
            guard let existingHash = try? Self.sha256(fileURL: existingURL) else { continue }
            if existingHash.caseInsensitiveCompare(contentHash) == .orderedSame {
                // A remote/local tombstone closes the logical identity. Do
                // not let content-hash deduplication resurrect that book
                // before the deterministic-ID tombstone check below runs.
                if let isTombstoned, await isTombstoned(existing.id) {
                    continue
                }
                Log.event("library.import.deduplicated", data: [
                    "book_id": existing.id.uuidString,
                    "format": format.rawValue,
                ])
                return existing
            }
        }

        var metadata = BookMetadata()
        if let extractor = metadataExtractors[ext] {
            metadata = await extractor.extractMetadata(from: sourceURL)
        }

        let deterministicID = DeterministicBookID.make(
            title: metadata.title,
            author: metadata.author,
            format: format,
            ownerId: ownerId
        )
        let bookId: BookID
        if let deterministicID,
           let isTombstoned,
           await isTombstoned(deterministicID) {
            // A deleted logical book ID is never reused. Re-importing the
            // same source creates a new entity instead of resurrecting a
            // tombstone that may still be pending locally or remotely.
            bookId = UUID()
            Log.event("library.import.identity.rotated", level: .info, data: [
                "deleted_book_id": deterministicID.uuidString,
                "new_book_id": bookId.uuidString,
            ])
        } else if let deterministicID,
                  let existing = try await bookStore.book(deterministicID),
                  existing.userId == ownerId {
            // Deterministic metadata identity is only a fallback. If the
            // content hash did not match above, do not overwrite another
            // edition that happens to share its title and author.
            bookId = UUID()
            Log.event("library.import.identity.rotated", level: .info, data: [
                "existing_book_id": existing.id.uuidString,
                "new_book_id": bookId.uuidString,
                "reason": "content_hash_mismatch",
            ])
        } else {
            bookId = deterministicID ?? UUID()
        }
        let bookDir = booksDirURL.appendingPathComponent(
            bookId.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: bookDir,
            withIntermediateDirectories: true
        )

        let filename = sourceURL.lastPathComponent
        let destURL = bookDir.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw BookFileStorage.StorageError.copyFailed(underlying: error)
        }

        var coverPath: String?
        if let extractor = coverExtractors[ext] {
            if let png = await extractor.extractCover(from: destURL) {
                let coverURL = bookDir.appendingPathComponent("cover.png")
                do {
                    try png.write(to: coverURL, options: .atomic)
                    coverPath = relativePath(of: coverURL)
                } catch {
                    Log.event(
                        "cover.write.failed",
                        level: .info,
                        data: [
                            "book": bookId.uuidString,
                            "error": String(describing: error),
                        ]
                    )
                }
            }
        }

        let book = Book(
            id: bookId,
            userId: ownerId,
            title: metadata.title ?? titleFallback(from: filename),
            author: metadata.author,
            formatType: format,
            addedAt: Date(),
            openedAt: nil,
            fileURL: relativePath(of: destURL),
            coverPath: coverPath
        )
        try await bookStore.upsert(book)
        NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)

        await bookIndexingHook.scheduleIndexing(for: book, fileURL: destURL)
        return book
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func ensureBooksDirExists() throws {
        if !fileManager.fileExists(atPath: booksDirURL.path) {
            try fileManager.createDirectory(
                at: booksDirURL,
                withIntermediateDirectories: true
            )
        }
    }

    private func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        if target.hasPrefix(root + "/") {
            return String(target.dropFirst(root.count + 1))
        }
        return target
    }

    private func titleFallback(from filename: String) -> String {
        let nameOnly = (filename as NSString).deletingPathExtension
        let withSpaces = nameOnly.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return withSpaces.isEmpty ? "Untitled" : withSpaces
    }
}

/// Serializes imports so the hash check and the subsequent store write are
/// one logical operation. Without this gate, two simultaneous imports of the
/// same bytes could both observe an empty library and create two UUIDs when
/// their metadata differs.
private actor BookImportGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}
