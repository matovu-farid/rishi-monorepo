import Foundation

public actor SharePackageService {
    public struct PendingShareResult: Sendable, Equatable {
        public let importedCount: Int
        public let discardedCount: Int

        public init(importedCount: Int, discardedCount: Int) {
            self.importedCount = importedCount
            self.discardedCount = discardedCount
        }
    }

    public enum ServiceError: Error, Sendable, Equatable {
        case missingUser
        case invalidBookFormat(String)
        case malformedDownloadURL
        case downloadFailed(Int)
        case missingResponseItems
        case accountChanged
    }

    private let workerClient: WorkerClient
    private let bookStore: any BookStore
    private let fileStorage: BookFileStorage
    private let syncBeforeCreate: @Sendable () async -> Void
    private let markBookDirty: @Sendable (BookID) async -> Void
    private let urlSession: URLSession
    private let pendingStore: PendingShareStore
    private let currentUserId: @Sendable () async -> UserID?

    public init(
        workerClient: WorkerClient,
        bookStore: any BookStore,
        fileStorage: BookFileStorage,
        syncEngine: SyncEngine,
        urlSession: URLSession = .shared,
        pendingStore: PendingShareStore = .shared,
        currentUserId: @escaping @Sendable () async -> UserID?
    ) {
        self.workerClient = workerClient
        self.bookStore = bookStore
        self.fileStorage = fileStorage
        self.syncBeforeCreate = { _ = await syncEngine.runOnce() }
        self.markBookDirty = { _ = await syncEngine.markBookDirty($0) }
        self.urlSession = urlSession
        self.pendingStore = pendingStore
        self.currentUserId = currentUserId
    }

    public init(
        workerClient: WorkerClient,
        bookStore: any BookStore,
        fileStorage: BookFileStorage,
        urlSession: URLSession = .shared,
        pendingStore: PendingShareStore = .shared,
        currentUserId: @escaping @Sendable () async -> UserID?,
        syncBeforeCreate: @escaping @Sendable () async -> Void,
        markBookDirty: @escaping @Sendable (BookID) async -> Void
    ) {
        self.workerClient = workerClient
        self.bookStore = bookStore
        self.fileStorage = fileStorage
        self.syncBeforeCreate = syncBeforeCreate
        self.markBookDirty = markBookDirty
        self.urlSession = urlSession
        self.pendingStore = pendingStore
        self.currentUserId = currentUserId
    }

    public func enqueue(token: String) async {
        await pendingStore.enqueue(token: token)
    }

    public func createShare(
        bookIDs: [BookID],
        kind: ShareKind,
        delivery: ShareDelivery,
        recipientUsername: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> SharePackageResponse {
        await syncBeforeCreate()
        return try await workerClient.send(
            ShareCreateEndpoint(body: .init(
                idempotencyKey: idempotencyKey,
                kind: kind,
                bookIDs: bookIDs.map(\.uuidString),
                delivery: delivery,
                recipientUsername: recipientUsername
            ))
        )
    }

    public func preview(token: String) async throws -> SharePreview {
        try await workerClient.send(SharePreviewEndpoint(token: token))
    }

    public func inbox() async throws -> [SharePreview] {
        try await workerClient.send(ShareInboxEndpoint()).shares
    }

    public func accept(packageID: String) async throws -> Int {
        guard let userID = await currentUserId() else { throw ServiceError.missingUser }
        await pendingStore.enqueueAcceptedPackage(packageID, userID: userID)
        let response = try await workerClient.send(ShareAcceptEndpoint(packageID: packageID))
        let imported = try await importItems(response: response, packageID: packageID, userID: userID)
        await pendingStore.removeAcceptedPackage(packageID, userID: userID)
        return imported
    }

    /// Called after authentication and onboarding are complete. Network and
    /// transfer failures intentionally remain queued for a later retry.
    public func redeemPendingIfEligible() async -> PendingShareResult {
        var importedCount = 0
        var discardedCount = 0
        guard let userID = await currentUserId() else {
            return PendingShareResult(importedCount: 0, discardedCount: 0)
        }
        for token in await pendingStore.tokens(for: userID) {
            await pendingStore.bindToken(token, to: userID)
            do {
                let response = try await workerClient.send(ShareRedeemEndpoint(token: token))
                guard response.items != nil else { throw ServiceError.missingResponseItems }
                importedCount += try await importItems(response: response, packageID: response.id, userID: userID)
                await pendingStore.remove(token: token)
            } catch {
                if isTerminalShareError(error) {
                    await pendingStore.remove(token: token)
                    discardedCount += 1
                }
                Log.error("sharing.pending_redeem.failed", error: error)
            }
        }

        for packageID in await pendingStore.acceptedPackageIDs(for: userID) {
            do {
                let response = try await workerClient.send(ShareAcceptEndpoint(packageID: packageID))
                importedCount += try await importItems(response: response, packageID: packageID, userID: userID)
                await pendingStore.removeAcceptedPackage(packageID, userID: userID)
            } catch {
                if isTerminalShareError(error) {
                    await pendingStore.removeAcceptedPackage(packageID, userID: userID)
                    discardedCount += 1
                }
                Log.error("sharing.pending_accept.failed", error: error)
            }
        }
        return PendingShareResult(importedCount: importedCount, discardedCount: discardedCount)
    }

    private func isTerminalShareError(_ error: Error) -> Bool {
        guard case let RishiError.network(code, _) = error else { return false }
        return [
            "SHARE_NOT_FOUND",
            "SHARE_EXPIRED",
            "SHARE_ALREADY_CLAIMED",
            "SHARE_INVALID_REQUEST",
            "SHARE_TOKEN_REQUIRED",
        ].contains(code)
    }

    private func importItems(
        response: SharePackageResponse,
        packageID: String,
        userID: UserID
    ) async throws -> Int {
        guard let items = response.items else { throw ServiceError.missingResponseItems }
        var imported = 0
        for item in items {
            guard await currentUserId() == userID else { throw ServiceError.accountChanged }
            let localID = await pendingStore.bookID(packageID: packageID, itemID: item.id) ?? UUID()
            guard let format = BookFormat(rawValue: item.format.lowercased()) else {
                throw ServiceError.invalidBookFormat(item.format)
            }
            let book = Book(
                id: localID,
                userId: userID,
                title: item.title,
                author: item.author,
                formatType: format,
                fileURL: "Books/\(localID.uuidString)/\(localID.uuidString).\(format.rawValue)"
            )
            if await pendingStore.bookID(packageID: packageID, itemID: item.id) == nil {
                await pendingStore.recordBookID(localID, packageID: packageID, itemID: item.id)
            }

            if try await bookStore.book(localID) == nil {
                guard let url = URL(string: item.fileURL) else { throw ServiceError.malformedDownloadURL }
                let (data, response) = try await urlSession.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw ServiceError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                guard await currentUserId() == userID else { throw ServiceError.accountChanged }
                let materialized = try fileStorage.materializeDownloadedBook(book, data: data)
                guard await currentUserId() == userID else { throw ServiceError.accountChanged }
                try await bookStore.upsert(materialized)
                guard await currentUserId() == userID else { throw ServiceError.accountChanged }
                await markBookDirty(localID)
                imported += 1
            }
        }
        return imported
    }
}
