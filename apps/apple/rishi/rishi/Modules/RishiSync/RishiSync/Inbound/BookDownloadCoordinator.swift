import Foundation

public struct VerifiedDownloadedBook: Sendable, Equatable {
    public let book: Book
    public let fingerprint: BookFileFingerprint

    public var sha256: String { fingerprint.sha256 }
    public var byteCount: Int64 { fingerprint.version.byteCount }

    public init(book: Book, fingerprint: BookFileFingerprint) {
        self.book = book
        self.fingerprint = fingerprint
    }
}

/// Downloads a server-owned book object and writes it into the platform-local
/// Books directory before returning a usable Book value.
public final class BookDownloadCoordinator: Sendable {
    public enum DownloadError: Error, Sendable {
        case missingUser
        case malformedURL
        case failed(status: Int)
        case remoteMetadataMismatch
    }

    private let workerClient: WorkerClient
    private let fileStorage: BookFileStorage
    private let userIdProvider: @Sendable () async -> String?
    private let urlSession: URLSession
    private let sourceProbe = CoordinatedSourceProbe()

    public init(
        workerClient: WorkerClient,
        fileStorage: BookFileStorage,
        userIdProvider: @escaping @Sendable () async -> String?,
        urlSession: URLSession = .shared
    ) {
        self.workerClient = workerClient
        self.fileStorage = fileStorage
        self.userIdProvider = userIdProvider
        self.urlSession = urlSession
    }

    public func downloadAndMaterialize(_ book: Book, r2Key: String?) async throws -> Book {
        try await downloadAndMaterializeVerified(book, r2Key: r2Key).book
    }

    public func downloadAndMaterializeVerified(
        _ book: Book,
        r2Key: String?,
        expectedRemoteSHA256: String? = nil,
        expectedRemoteByteCount: Int64? = nil
    ) async throws -> VerifiedDownloadedBook {
        guard let userId = await userIdProvider() else { throw DownloadError.missingUser }
        let key = r2Key ?? BookUploader.r2Key(for: book, userId: userId)
        let response = try await workerClient.send(SyncDownloadURLEndpoint(body: .init(key: key)))
        guard let url = URL(string: response.url) else { throw DownloadError.malformedURL }
        let (data, transport) = try await urlSession.data(from: url)
        guard let http = transport as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.failed(status: (transport as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let receivedDigest = await sourceProbe.digestDownloadedData(data)
        guard expectedRemoteSHA256.map({ receivedDigest.sha256.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
              expectedRemoteByteCount.map({ receivedDigest.byteCount == $0 }) ?? true else {
            throw DownloadError.remoteMetadataMismatch
        }
        let materialized = try fileStorage.materializeDownloadedBook(book, data: data)
        guard let fingerprint = await fileStorage.cacheVerifiedManagedFile(
            for: materialized,
            expectedSHA256: receivedDigest.sha256,
            expectedByteCount: receivedDigest.byteCount
        ) else { throw DownloadError.remoteMetadataMismatch }
        return VerifiedDownloadedBook(book: materialized, fingerprint: fingerprint.fingerprint)
    }
}
