import CryptoKit
import Foundation

actor SessionBookService {
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

    func prepare(book: SharedReadingBook, ownerId: UserID) async throws -> String {
        guard await userIdProvider() == ownerId else { throw ServiceError.accountChanged }
        guard let downloadURL = book.downloadURL else { throw ServiceError.downloadFailed }
        let (temporaryURL, response) = try await session.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.downloadFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value == book.fileSize else {
            throw ServiceError.invalidSize
        }
        let digest = try Self.sha256(fileURL: temporaryURL)
        guard digest.caseInsensitiveCompare(book.contentHash) == .orderedSame else {
            throw ServiceError.hashMismatch
        }
        guard await userIdProvider() == ownerId else { throw ServiceError.accountChanged }
        _ = try await fileStorage.importBook(from: temporaryURL, ownerId: ownerId)
        return digest
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
