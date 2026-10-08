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
        case accountChanged
        case missingUser
        case malformedURL
        case failed(status: Int)
        case remoteMetadataMismatch
    }

    private let workerClient: WorkerClient
    private let fileStorage: BookFileStorage
    private let userIdProvider: @Sendable () async -> String?
    private let urlSession: URLSession
    private let metadataStore: (any SyncMetadataStore)?
    private let isCurrentAccountPermit: (@Sendable (AccountMutationPermit) async -> Bool)?
    private let admitAccountOperation: (@Sendable (AccountMutationPermit) async -> BookImportOperationLease?)?
    private let sourceProbe = CoordinatedSourceProbe()

    public init(
        workerClient: WorkerClient,
        fileStorage: BookFileStorage,
        userIdProvider: @escaping @Sendable () async -> String?,
        urlSession: URLSession = .shared,
        metadataStore: (any SyncMetadataStore)? = nil,
        isCurrentAccountPermit: (@Sendable (AccountMutationPermit) async -> Bool)? = nil,
        admitAccountOperation: (@Sendable (AccountMutationPermit) async -> BookImportOperationLease?)? = nil
    ) {
        self.workerClient = workerClient
        self.fileStorage = fileStorage
        self.userIdProvider = userIdProvider
        self.urlSession = urlSession
        self.metadataStore = metadataStore
        self.isCurrentAccountPermit = isCurrentAccountPermit
        self.admitAccountOperation = admitAccountOperation
    }

    public func downloadAndMaterialize(_ book: Book, r2Key: String?) async throws -> Book {
        try await downloadAndMaterializeVerified(book, r2Key: r2Key).book
    }

    public func downloadAndMaterializeVerified(
        _ book: Book,
        r2Key: String?,
        expectedRemoteSHA256: String? = nil,
        expectedRemoteByteCount: Int64? = nil,
        accountPermit: AccountMutationPermit? = nil
    ) async throws -> VerifiedDownloadedBook {
        try await validateAuthority(accountPermit, book: book)
        guard let userId = await userIdProvider() else { throw DownloadError.missingUser }
        try await validateAuthority(accountPermit, book: book)
        let key = r2Key ?? BookUploader.r2Key(for: book, userId: userId)
        let response = try await workerClient.send(SyncDownloadURLEndpoint(body: .init(key: key)))
        try await validateAuthority(accountPermit, book: book)
        guard let url = URL(string: response.url) else { throw DownloadError.malformedURL }
        let (data, transport) = try await urlSession.data(from: url)
        try await validateAuthority(accountPermit, book: book)
        guard let http = transport as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.failed(status: (transport as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let receivedDigest = await sourceProbe.digestDownloadedData(data)
        try await validateAuthority(accountPermit, book: book)
        guard expectedRemoteSHA256.map({ receivedDigest.sha256.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
              expectedRemoteByteCount.map({ receivedDigest.byteCount == $0 }) ?? true else {
            throw DownloadError.remoteMetadataMismatch
        }
        let lease: BookImportOperationLease?
        if let admitAccountOperation {
            guard let accountPermit, let admitted = await admitAccountOperation(accountPermit) else { throw DownloadError.accountChanged }
            lease = admitted
        } else { lease = nil }
        defer { lease?.release() }
        try await validateAuthority(accountPermit, book: book)
        let commit: @Sendable () async throws -> VerifiedDownloadedBook = {
            try await self.validateAuthority(accountPermit, book: book)
            let materialized = try self.fileStorage.materializeDownloadedBook(book, data: data)
            try await self.validateAuthority(accountPermit, book: book)
            guard let fingerprint = await self.fileStorage.cacheVerifiedManagedFile(
                for: materialized,
                expectedSHA256: receivedDigest.sha256,
                expectedByteCount: receivedDigest.byteCount
            ) else { throw DownloadError.remoteMetadataMismatch }
            try await self.validateAuthority(accountPermit, book: book)
            return VerifiedDownloadedBook(book: materialized, fingerprint: fingerprint.fingerprint)
        }
        if let metadataStore { return try await metadataStore.withLiveBookIdentity(book.id, operation: commit) }
        return try await commit()
    }

    private func validateAuthority(_ permit: AccountMutationPermit?, book: Book) async throws {
        try Task.checkCancellation()
        guard let isCurrentAccountPermit else { return }
        guard let permit, permit.ownerID == book.userId, await isCurrentAccountPermit(permit) else { throw DownloadError.accountChanged }
    }
}
