import Foundation
import Testing

@testable import rishi

private final class ShareServiceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var secondItemAvailable = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler,
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Share package service", .serialized)
struct SharePackageServiceTests {
    @Test("partial bundle failures retain the token and reuse completed item IDs")
    func partialBundleRetry() async throws {
        let userID = UUID()
        let root = URL.temporaryDirectory
            .appendingPathComponent("SharePackageService-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultsSuiteName = "rishi.share-service.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let pendingStore = PendingShareStore(defaults: defaults, key: "pending")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let bookStore = InMemoryBookStore()
        let fileStorage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: [:]
        )
        let workerConfiguration = URLSessionConfiguration.ephemeral
        workerConfiguration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let workerSession = URLSession(configuration: workerConfiguration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: workerSession,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        let downloadConfiguration = URLSessionConfiguration.ephemeral
        downloadConfiguration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let downloadSession = URLSession(configuration: downloadConfiguration)

        ShareServiceMockURLProtocol.secondItemAvailable = false
        defer {
            ShareServiceMockURLProtocol.handler = nil
            ShareServiceMockURLProtocol.secondItemAvailable = false
        }
        ShareServiceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/shares/redeem" {
                return (200, Data(#"{"id":"package-1","items":[{"id":"item-1","title":"First","author":"Author","format":"epub","file_size":5,"file_url":"https://files.test/item-1"},{"id":"item-2","title":"Second","author":null,"format":"epub","file_size":6,"file_url":"https://files.test/item-2"}]}"#.utf8))
            }
            if request.url?.host == "files.test" {
                if request.url?.path == "/item-2" && !ShareServiceMockURLProtocol.secondItemAvailable {
                    return (500, Data("temporary failure".utf8))
                }
                return (200, Data("book-data".utf8))
            }
            return (404, Data())
        }

        await pendingStore.enqueue(token: "share-token")
        let service = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: fileStorage,
            urlSession: downloadSession,
            pendingStore: pendingStore,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )

        let firstResult = await service.redeemPendingIfEligible()
        let firstBooks = await bookStore.snapshot()
        #expect(firstResult.importedCount == 1)
        #expect(firstBooks.count == 1)
        #expect(await pendingStore.tokens() == ["share-token"])
        let firstID = try #require(firstBooks.first?.id)

        ShareServiceMockURLProtocol.secondItemAvailable = true
        let secondResult = await service.redeemPendingIfEligible()
        let finalBooks = await bookStore.snapshot()
        #expect(secondResult.importedCount == 1)
        #expect(finalBooks.count == 2)
        #expect(finalBooks.contains { $0.id == firstID })
        #expect(await pendingStore.tokens().isEmpty)
    }

    @Test("materialization failures keep the token queued and reuse the recorded ID")
    func materializationFailureRetry() async throws {
        let userID = UUID()
        let suiteName = "rishi.share-service.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pendingStore = PendingShareStore(defaults: defaults, key: "pending")
        let failingRoot = URL.temporaryDirectory.appendingPathComponent("ShareFailure-\(UUID().uuidString)")
        let workingRoot = URL.temporaryDirectory.appendingPathComponent("ShareRetry-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: failingRoot)
            try? FileManager.default.removeItem(at: workingRoot)
            ShareServiceMockURLProtocol.handler = nil
        }
        try Data("not-a-directory".utf8).write(to: failingRoot)

        let bookStore = InMemoryBookStore()
        let failingStorage = BookFileStorage(rootURL: failingRoot, bookStore: bookStore, coverExtractors: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        ShareServiceMockURLProtocol.handler = { request in
            if request.url?.path == "/api/shares/redeem" {
                return (200, Data(#"{"id":"package-materialize","items":[{"id":"item-1","title":"Book","author":null,"format":"epub","file_size":5,"file_url":"https://files.test/item-1"}]}"#.utf8))
            }
            if request.url?.host == "files.test" {
                return (200, Data("book-data".utf8))
            }
            return (404, Data())
        }
        await pendingStore.enqueue(token: "materialize-token")
        let failingService = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: failingStorage,
            urlSession: session,
            pendingStore: pendingStore,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )

        let first = await failingService.redeemPendingIfEligible()
        let recordedID = try #require(await pendingStore.bookID(packageID: "package-materialize", itemID: "item-1"))
        #expect(first.importedCount == 0)
        #expect(await bookStore.snapshot().isEmpty)
        #expect(await pendingStore.tokens() == ["materialize-token"])

        let retryService = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: BookFileStorage(rootURL: workingRoot, bookStore: bookStore, coverExtractors: [:]),
            urlSession: session,
            pendingStore: pendingStore,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )
        let second = await retryService.redeemPendingIfEligible()
        #expect(second.importedCount == 1)
        #expect(await bookStore.snapshot().first?.id == recordedID)
        #expect(await pendingStore.tokens().isEmpty)
    }
}
