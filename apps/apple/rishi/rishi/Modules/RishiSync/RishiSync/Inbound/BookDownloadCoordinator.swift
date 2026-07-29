import Foundation

/// Downloads a server-owned book object and writes it into the platform-local
/// Books directory before returning a usable Book value.
public final class BookDownloadCoordinator: Sendable {
    public enum DownloadError: Error, Sendable {
        case missingUser
        case malformedURL
        case failed(status: Int)
    }

    private let workerClient: WorkerClient
    private let fileStorage: BookFileStorage
    private let userIdProvider: @Sendable () async -> String?
    private let urlSession: URLSession

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
        guard let userId = await userIdProvider() else { throw DownloadError.missingUser }
        let key = r2Key ?? BookUploader.r2Key(for: book, userId: userId)
        let response = try await workerClient.send(SyncDownloadURLEndpoint(body: .init(key: key)))
        guard let url = URL(string: response.url) else { throw DownloadError.malformedURL }
        let (data, transport) = try await urlSession.data(from: url)
        guard let http = transport as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.failed(status: (transport as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try fileStorage.materializeDownloadedBook(book, data: data)
    }
}
