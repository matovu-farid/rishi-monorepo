import CryptoKit
import Foundation

public actor SharePackageService {
    public static let libraryDidChange = Notification.Name("Rishi.sharedBookImported")
    public struct PendingShareResult: Sendable, Equatable {
        public let importedCount: Int
        public let discardedCount: Int
        public let alreadyUsedCount: Int

        public init(importedCount: Int, discardedCount: Int, alreadyUsedCount: Int = 0) {
            self.importedCount = importedCount
            self.discardedCount = discardedCount
            self.alreadyUsedCount = alreadyUsedCount
        }
    }

    public enum ServiceError: Error, Sendable, Equatable {
        case missingUser
        case invalidBookFormat(String)
        case malformedDownloadURL
        case downloadFailed(Int)
        case missingResponseItems
        case accountChanged
        case alreadyUsed
    }

    private let workerClient: WorkerClient
    private let bookStore: any BookStore
    private let fileStorage: BookFileStorage
    private let syncBeforeCreate: @Sendable () async -> Void
    private let markBookDirty: @Sendable (BookID) async -> Void
    private let urlSession: URLSession
    private let pendingStore: PendingShareStore
    private let currentUserId: @Sendable () async -> UserID?
    private var pendingRedemptionInFlight = false

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
        access: ShareAccess,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> SharePackageResponse {
        await syncBeforeCreate()
        return try await workerClient.send(
            ShareCreateEndpoint(body: .init(
                idempotencyKey: idempotencyKey,
                kind: kind,
                bookIDs: bookIDs.map(\.uuidString),
                access: access
            ))
        )
    }

    public func preview(token: String) async throws -> SharePreview {
        try await workerClient.send(SharePreviewEndpoint(token: token))
    }

    /// Called after authentication and onboarding are complete. Network and
    /// transfer failures intentionally remain queued for a later retry.
    public func redeemPendingIfEligible() async -> PendingShareResult {
        guard !pendingRedemptionInFlight else {
            return PendingShareResult(importedCount: 0, discardedCount: 0, alreadyUsedCount: 0)
        }
        pendingRedemptionInFlight = true
        defer { pendingRedemptionInFlight = false }

        var importedCount = 0
        var discardedCount = 0
        var alreadyUsedCount = 0
        guard let userID = await currentUserId() else {
            return PendingShareResult(importedCount: 0, discardedCount: 0, alreadyUsedCount: 0)
        }
        for token in await pendingStore.tokens(for: userID) {
            await pendingStore.bindToken(token, to: userID)
            do {
                let response = try await workerClient.send(ShareRedeemEndpoint(token: token))
                guard response.items != nil else { throw ServiceError.missingResponseItems }
                importedCount += try await importItems(response: response, packageID: response.id, userID: userID)
                await pendingStore.remove(token: token)
                if importedCount > 0 {
                    NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
                }
            } catch {
                if isTerminalShareError(error) {
                    await pendingStore.remove(token: token)
                    discardedCount += 1
                    if case let RishiError.network(code, _) = error, code == "SHARE_ALREADY_CLAIMED" {
                        alreadyUsedCount += 1
                    }
                }
                Log.error("sharing.pending_redeem.failed", error: error)
            }
        }

        return PendingShareResult(importedCount: importedCount, discardedCount: discardedCount, alreadyUsedCount: alreadyUsedCount)
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
        var existingBooks = (try? await bookStore.books(for: userID)) ?? []
        for item in items {
            guard await currentUserId() == userID else { throw ServiceError.accountChanged }
            guard let format = BookFormat(rawValue: item.format.lowercased()) else {
                throw ServiceError.invalidBookFormat(item.format)
            }
            if await alreadyOwns(item, among: existingBooks) {
                continue
            }
            let localID = await pendingStore.bookID(packageID: packageID, itemID: item.id)
                ?? DeterministicBookID.make(title: item.title, author: item.author, format: format)
                ?? UUID()
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
                existingBooks.append(materialized)
                guard await currentUserId() == userID else { throw ServiceError.accountChanged }
                await markBookDirty(localID)
                imported += 1
            }
        }
        return imported
    }

    private func alreadyOwns(
        _ item: ShareDownloadItem,
        among books: [Book]
    ) async -> Bool {
        let identity = bookIdentity(title: item.title, author: item.author, format: item.format)
        if books.contains(where: {
            bookIdentity(title: $0.title, author: $0.author, format: $0.formatType.rawValue) == identity
        }) {
            return true
        }

        if let fileHash = item.fileHash, !fileHash.isEmpty {
            for book in books {
                let url = fileStorage.absoluteFileURL(for: book)
                guard let data = try? Data(contentsOf: url) else { continue }
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                if digest.caseInsensitiveCompare(fileHash) == .orderedSame {
                    return true
                }
            }
        }

        // Older share rows may not have a file hash. The metadata identity
        // check above is the compatibility fallback for those rows.
        return false
    }

    private func bookIdentity(title: String, author: String?, format: String) -> String {
        [title, author ?? "", format]
            .map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\u{1F}")
    }
}
