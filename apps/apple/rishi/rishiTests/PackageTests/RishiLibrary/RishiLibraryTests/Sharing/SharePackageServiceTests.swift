import CryptoKit
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

private final class LockIsolatedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LockIsolatedOptionalUUID: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UUID?

    init(_ value: UUID?) { storage = value }

    var value: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var uuidString: String {
        value?.uuidString ?? "missing"
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                signaled = false
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        let continuation = waiters.isEmpty ? nil : waiters.removeFirst()
        if continuation == nil {
            signaled = true
        }
        lock.unlock()
        continuation?.resume()
    }
}

@Suite("Share package service", .serialized)
struct SharePackageServiceTests {
    @Test("single-book shares reuse a prepared response instead of creating duplicate packages")
    func singleBookShareReusesPreparedResponse() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = URL.temporaryDirectory.appendingPathComponent("SharePrepare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookStore = InMemoryBookStore()
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        let prepareCount = LockIsolatedInt()
        defer { ShareServiceMockURLProtocol.handler = nil }
        ShareServiceMockURLProtocol.handler = { request in
            if request.url?.path == "/api/shares/prepare" {
                prepareCount.increment()
                return (200, Data("{\"links\":[{\"book_id\":\"\(bookID.uuidString)\",\"public\":{\"id\":\"package-prepared\",\"expires_at\":900000000,\"link\":\"https://rishi.test/prepared\"},\"one_time\":{\"id\":\"package-one-time\",\"expires_at\":900000000,\"link\":\"https://rishi.test/one-time\"}}],\"skipped\":[]}".utf8))
            }
            if request.url?.path == "/api/shares" {
                return (500, Data("create endpoint must not be used for a single book".utf8))
            }
            return (404, Data())
        }

        let service = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: fileStorage,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )

        let first = try await service.createShare(bookIDs: [bookID], kind: .single, access: .public)
        let second = try await service.createShare(bookIDs: [bookID], kind: .single, access: .public)
        let oneTimeFirst = try await service.createShare(bookIDs: [bookID], kind: .single, access: .oneTime)
        let oneTimeSecond = try await service.createShare(bookIDs: [bookID], kind: .single, access: .oneTime)
        #expect(first.link == "https://rishi.test/prepared")
        #expect(second.id == "package-prepared")
        #expect(oneTimeFirst.link == "https://rishi.test/one-time")
        #expect(oneTimeSecond.id == "package-one-time")
        #expect(prepareCount.value == 3)
    }

    @Test("prepared links are partitioned when the authenticated account changes")
    func preparedLinksDoNotCrossAccounts() async throws {
        let firstUser = UUID()
        let secondUser = UUID()
        let bookID = UUID()
        let currentUser = LockIsolatedOptionalUUID(firstUser)
        let root = URL.temporaryDirectory.appendingPathComponent("SharePrepareAccount-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookStore = InMemoryBookStore()
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        let prepareCount = LockIsolatedInt()
        defer { ShareServiceMockURLProtocol.handler = nil }
        ShareServiceMockURLProtocol.handler = { request in
            if request.url?.path == "/api/shares/prepare" {
                let userSuffix = currentUser.uuidString
                prepareCount.increment()
                return (200, Data("{\"links\":[{\"book_id\":\"\(bookID.uuidString)\",\"public\":{\"id\":\"package-\(userSuffix)\",\"expires_at\":900000000,\"link\":\"https://rishi.test/\(userSuffix)\"},\"one_time\":{\"id\":\"one-time-\(userSuffix)\",\"expires_at\":900000000,\"link\":\"https://rishi.test/one-time-\(userSuffix)\"}}],\"skipped\":[]}".utf8))
            }
            return (404, Data())
        }

        let service = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: fileStorage,
            currentUserId: { currentUser.value },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )
        let first = try await service.createShare(bookIDs: [bookID], kind: .single, access: .public)
        currentUser.value = secondUser
        let second = try await service.createShare(bookIDs: [bookID], kind: .single, access: .public)
        #expect(first.link != second.link)
        #expect(prepareCount.value == 2)
    }

    @Test("prewarm batches at fifty and skips already-fresh access entries")
    func prewarmBatchesAndReusesFreshEntries() async throws {
        let userID = UUID()
        let bookIDs = (0..<51).map { _ in UUID() }
        let root = URL.temporaryDirectory.appendingPathComponent("SharePrewarm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookStore = InMemoryBookStore()
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        let prepareCount = LockIsolatedInt()
        defer { ShareServiceMockURLProtocol.handler = nil }
        ShareServiceMockURLProtocol.handler = { request in
            guard request.url?.path == "/api/shares/prepare" else { return (404, Data()) }
            prepareCount.increment()
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let ids = json?["book_ids"] as? [String] ?? []
            let prepared = ids.flatMap { bookID in
                [[
                    "book_id": bookID,
                    "public": [
                        "id": "package-\(bookID)-public",
                        "expires_at": 900000000,
                        "link": "https://rishi.test/\(bookID)/public",
                    ],
                    "one_time": [
                        "id": "package-\(bookID)-one-time",
                        "expires_at": 900000000,
                        "link": "https://rishi.test/\(bookID)/one-time",
                    ],
                ] as [String: Any]]
            }
            let payload: [String: Any] = ["links": prepared, "skipped": []]
            return (200, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }

        let service = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: fileStorage,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )
        await service.prewarm(bookIDs: bookIDs + bookIDs)
        await service.prewarm(bookIDs: bookIDs)
        #expect(prepareCount.value == 2)
    }

    @Test("redeeming a book already in the library is a no-op")
    func existingBookIsNotDuplicated() async throws {
        let userID = UUID()
        let root = URL.temporaryDirectory
            .appendingPathComponent("SharePackageExisting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "rishi.share-service.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pendingStore = PendingShareStore(defaults: defaults, key: "pending")
        let existing = Book(
            userId: userID,
            title: "Existing Local Title",
            author: "Author",
            formatType: .epub,
            fileURL: "Books/already-owned.epub"
        )
        let existingData = Data("already-owned-book".utf8)
        let existingDirectory = root.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        try existingData.write(to: root.appendingPathComponent(existing.fileURL))
        let existingHash = SHA256.hash(data: existingData).map { String(format: "%02x", $0) }.joined()
        let bookStore = InMemoryBookStore(initial: [existing])
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        defer { ShareServiceMockURLProtocol.handler = nil }
        ShareServiceMockURLProtocol.handler = { request in
            if request.url?.path == "/api/shares/redeem" {
                return (200, Data("{\"id\":\"package-existing\",\"items\":[{\"id\":\"item-1\",\"title\":\"Already Owned\",\"author\":\"Author\",\"format\":\"epub\",\"file_size\":5,\"file_hash\":\"\(existingHash)\",\"file_url\":\"https://files.test/item-1\"}]}".utf8))
            }
            return (500, Data("duplicate download should not happen".utf8))
        }

        await pendingStore.enqueue(token: "existing-book-token")
        let service = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: fileStorage,
            urlSession: session,
            pendingStore: pendingStore,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )

        let result = await service.redeemPendingIfEligible()
        #expect(result.importedCount == 0)
        #expect(await bookStore.snapshot().count == 1)
        #expect(await pendingStore.tokens().isEmpty)
    }

    @Test("redemption reruns when another share arrives during an active redemption")
    func redemptionRerunsForRequestsDuringActiveRedemption() async throws {
        let userID = UUID()
        let root = URL.temporaryDirectory.appendingPathComponent("ShareCoalescing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultsSuiteName = "rishi.share-service.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let pendingStore = PendingShareStore(defaults: defaults, key: "pending")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let bookStore = InMemoryBookStore()
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        let firstRedeemStarted = AsyncSignal()
        let releaseFirstRedeem = AsyncSignal()
        let redeemCount = LockIsolatedInt()
        defer { ShareServiceMockURLProtocol.handler = nil }
        ShareServiceMockURLProtocol.handler = { request in
            if request.url?.path == "/api/shares/redeem" {
                let requestNumber = redeemCount.value + 1
                redeemCount.increment()
                if requestNumber == 1 {
                    firstRedeemStarted.signal()
                    releaseFirstRedeem.wait()
                }
                let packageID = requestNumber == 1 ? "package-one" : "package-two"
                let itemID = requestNumber == 1 ? "item-one" : "item-two"
                return (200, Data("{\"id\":\"\(packageID)\",\"items\":[{\"id\":\"\(itemID)\",\"title\":\"Book \(requestNumber)\",\"author\":null,\"format\":\"epub\",\"file_size\":4,\"file_url\":\"https://files.test/\(itemID)\"}]}".utf8))
            }
            if request.url?.host == "files.test" {
                return (200, Data("book-data".utf8))
            }
            return (404, Data())
        }

        await pendingStore.enqueue(token: "first-share-token")
        let service = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: fileStorage,
            urlSession: session,
            pendingStore: pendingStore,
            currentUserId: { userID },
            syncBeforeCreate: {},
            markBookDirty: { _ in }
        )

        let firstTask = Task { await service.redeemPendingIfEligible() }
        await firstRedeemStarted.wait()
        await pendingStore.enqueue(token: "second-share-token")

        // This request overlaps the first pass and must cause a follow-up pass.
        let overlappingTask = Task { await service.redeemPendingIfEligible() }
        await Task.yield()

        // The view that initiated the first call may be torn down while the
        // app transitions accounts. The service-owned task must keep going.
        firstTask.cancel()
        releaseFirstRedeem.signal()
        let firstResult = await firstTask.value
        let overlappingResult = await overlappingTask.value
        #expect(overlappingResult.importedCount == 2)
        #expect(firstResult.importedCount == 2)
        #expect(await bookStore.snapshot().count == 2)
        #expect(await pendingStore.tokens().isEmpty)
    }

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
        let recordedID = try #require(await pendingStore.bookID(token: "materialize-token", userID: userID, packageID: "package-materialize", itemID: "item-1"))
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
