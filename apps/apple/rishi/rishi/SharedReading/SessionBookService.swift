import CryptoKit
import Foundation

actor SessionBookService {
    struct PreparedBook: Sendable {
        let book: Book
        let contentHash: String
    }

    enum ServiceError: Error, Sendable, Equatable {
        case downloadFailed
        case invalidSize
        case hashMismatch
        case accountChanged
    }

    private let fileStorage: BookFileStorage
    private let userIdProvider: @Sendable () async -> UserID?
    private let session: URLSession

    init(
        fileStorage: BookFileStorage,
        userIdProvider: @escaping @Sendable () async -> UserID?,
        session: URLSession = .shared
    ) {
        self.fileStorage = fileStorage
        self.userIdProvider = userIdProvider
        self.session = session
    }

    func prepare(book: SharedReadingBook, ownerId: UserID) async throws -> PreparedBook {
        Log.event("sharing.session.book.prepare.started", data: ["book_id": book.bookId])
        guard await userIdProvider() == ownerId else {
            let error = ServiceError.accountChanged
            Log.error("sharing.session.book.prepare.failed", error: error)
            throw error
        }
        guard let downloadURL = book.downloadURL else {
            let error = ServiceError.downloadFailed
            Log.error("sharing.session.book.prepare.failed", error: error)
            throw error
        }
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: downloadURL)
        } catch {
            Log.error("sharing.session.book.download.failed", error: error)
            throw ServiceError.downloadFailed
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let error = ServiceError.downloadFailed
            Log.event("sharing.session.book.download.response", level: .error, data: ["status": String(status)])
            Log.error("sharing.session.book.download.failed", error: error)
            throw error
        }
        let importURL = temporaryURL
            .deletingPathExtension()
            .appendingPathExtension(book.format.rawValue)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: importURL)
        } catch {
            Log.error("sharing.session.book.rename.failed", error: error)
            throw error
        }
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: importURL)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: importURL.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == book.fileSize else {
            let error = ServiceError.invalidSize
            Log.event("sharing.session.book.size_mismatch", level: .error, data: [
                "expected_size": String(book.fileSize),
                "actual_size": String(actualSize),
            ])
            Log.error("sharing.session.book.prepare.failed", error: error)
            throw error
        }
        let digest = try Self.sha256(fileURL: importURL)
        guard digest.caseInsensitiveCompare(book.contentHash) == .orderedSame else {
            let error = ServiceError.hashMismatch
            Log.event("sharing.session.book.hash_mismatch", level: .error, data: [
                "downloaded_hash": digest,
                "expected_hash": book.contentHash,
            ])
            Log.error("sharing.session.book.prepare.failed", error: error)
            throw error
        }
        guard await userIdProvider() == ownerId else {
            let error = ServiceError.accountChanged
            Log.error("sharing.session.book.prepare.failed", error: error)
            throw error
        }
        let importedBook: Book
        do {
            importedBook = try await fileStorage.importBook(
                from: importURL,
                ownerId: ownerId,
                expectedContentHash: digest
            )
        } catch {
            Log.error("sharing.session.book.import.failed", error: error)
            throw error
        }
        Log.event("sharing.session.book.prepare.completed", data: ["book_id": book.bookId])
        return PreparedBook(book: importedBook, contentHash: digest)
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
}
