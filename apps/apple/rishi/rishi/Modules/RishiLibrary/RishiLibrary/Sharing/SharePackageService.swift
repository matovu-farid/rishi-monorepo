import CryptoKit
import Foundation

public actor SharePackageService {
    public static let libraryDidChange = Notification.Name("Rishi.sharedBookImported")
    private static let prepareBatchLimit = 50
    private static let publicFreshnessWindow: TimeInterval = 60
    private static let oneTimeCacheTTL: TimeInterval = 15

    private struct PreparedCacheKey: Hashable, Sendable {
        let userID: UserID
        let bookID: BookID
        let access: ShareAccess
    }

    private struct PreparedCacheEntry: Sendable {
        let package: SharePreparedPackage
        let cachedAt: Date
    }

    private struct PrewarmKey: Hashable, Sendable {
        let userID: UserID
        let bookIDs: [BookID]
    }

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
    private var preparedCache: [PreparedCacheKey: PreparedCacheEntry] = [:]
    private var prewarmTasks: [PrewarmKey: Task<Void, Never>] = [:]
    private var handedOutOneTimePackageIDs: Set<String> = []
    private var activeUserID: UserID?

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
        if kind == .single, bookIDs.count == 1, let bookID = bookIDs.first {
            do {
                // A freshly prewarmed link is already server-backed. Return it
                // without putting the sync engine back on the share tap's
                // critical path.
                return try await preparedShare(bookID: bookID, access: access)
            } catch {
                // A newly imported book may not have reached D1 yet. Sync once
                // only when preparation could not produce a link, then retry
                // the durable slot lookup.
                await syncBeforeCreate()
                return try await preparedShare(bookID: bookID, access: access, forceRefresh: true)
            }
        }

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

    /// Ensures durable public and one-time slots for individual books. This is
    /// intentionally best-effort and does not run a sync first; callers use it
    /// after a library refresh so it cannot delay first paint.
    public func prewarm(bookIDs: [BookID]) async {
        guard let userID = try? await currentAccount() else { return }
        let normalized = normalizedBookIDs(bookIDs)
        guard !normalized.isEmpty else { return }
        let booksToPrepare = normalized.filter { needsPrewarm(for: $0, userID: userID) }
        guard !booksToPrepare.isEmpty else { return }

        for chunk in booksToPrepare.chunked(maxCount: Self.prepareBatchLimit) {
            guard await currentUserId() == userID else { return }
            let pendingChunk = chunk.filter { needsPrewarm(for: $0, userID: userID) }
            guard !pendingChunk.isEmpty else { continue }
            let key = PrewarmKey(userID: userID, bookIDs: pendingChunk)
            if let existing = prewarmTasks[key] {
                await existing.value
                continue
            }

            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.prepareForAccount(bookIDs: pendingChunk, userID: userID)
                } catch is CancellationError {
                    return
                } catch {
                    Log.error("sharing.prewarm.failed", error: error)
                }
            }
            prewarmTasks[key] = task
            await task.value
            if prewarmTasks[key] != nil {
                prewarmTasks[key] = nil
            }
        }
    }

    /// Explicit lifecycle hook for sign-out/account changes. The current-user
    /// closure is still checked around every request to fence stale results.
    public func accountDidChange() {
        invalidatePreparedCache()
    }

    /// Returns a prepared single-book response, refreshing it when the local
    /// freshness policy says the cached slot is no longer safe to use.
    public func preparedShare(
        bookID: BookID,
        access: ShareAccess,
        forceRefresh: Bool = false
    ) async throws -> SharePackageResponse {
        let userID = try await currentAccount()
        let key = PreparedCacheKey(userID: userID, bookID: bookID, access: access)
        if !forceRefresh,
           let cached = preparedCache[key], isFresh(cached, access: access) {
            try await ensureAccount(userID)
            if access == .oneTime {
                // A bearer may be claimed by another device between prewarm
                // and the share tap. Do not replay this cached generation on
                // the next share action.
                preparedCache.removeValue(forKey: key)
                handedOutOneTimePackageIDs.insert(cached.package.id)
            }
            return cached.package.packageResponse
        }

        let response = try await prepareForAccount(bookIDs: [bookID], userID: userID)
        guard let preparedBook = response.links.first(where: {
            $0.bookID.caseInsensitiveCompare(bookID.uuidString) == .orderedSame
        }) else {
            let reason = response.skipped.first(where: {
                $0.bookID.caseInsensitiveCompare(bookID.uuidString) == .orderedSame
            })?.code
                ?? "No prepared link was returned."
            throw RishiError.network(code: "SHARE_BOOK_NOT_READY", message: reason)
        }
        try await ensureAccount(userID)
        if access == .oneTime {
            // The freshly returned one-time URL is now handed to the share
            // sheet. Do not leave the same bearer in the actor cache after
            // this action.
            preparedCache.removeValue(forKey: key)
            handedOutOneTimePackageIDs.insert((preparedBook.oneTime).id)
        }
        return (access == .public ? preparedBook.public : preparedBook.oneTime).packageResponse
    }

    /// Sends prepare directly for callers that need to inspect per-book skips.
    /// Successful links are cached; skipped books are deliberately not cached.
    public func prepare(bookIDs: [BookID]) async throws -> SharePrepareResponse {
        let userID = try await currentAccount()
        let response = try await prepareForAccount(bookIDs: normalizedBookIDs(bookIDs), userID: userID)
        try await ensureAccount(userID)
        return response
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

    private func currentAccount() async throws -> UserID {
        guard let userID = await currentUserId() else {
            invalidatePreparedCache()
            throw ServiceError.missingUser
        }
        if activeUserID != userID {
            invalidatePreparedCache()
            activeUserID = userID
        }
        return userID
    }

    private func ensureAccount(_ userID: UserID) async throws {
        guard await currentUserId() == userID, activeUserID == userID else {
            invalidatePreparedCache()
            throw ServiceError.accountChanged
        }
    }

    private func invalidatePreparedCache() {
        preparedCache.removeAll(keepingCapacity: true)
        handedOutOneTimePackageIDs.removeAll(keepingCapacity: true)
        for task in prewarmTasks.values {
            task.cancel()
        }
        prewarmTasks.removeAll(keepingCapacity: true)
    }

    private func normalizedBookIDs(_ bookIDs: [BookID]) -> [BookID] {
        Array(Set(bookIDs)).sorted { $0.uuidString < $1.uuidString }
    }

    private func isFresh(_ entry: PreparedCacheEntry, access: ShareAccess, now: Date = Date()) -> Bool {
        guard !entry.package.link.isEmpty else { return false }
        if let expiresAt = entry.package.expiresAt, expiresAt <= now {
            return false
        }
        switch access {
        case .public:
            guard let expiresAt = entry.package.expiresAt else { return true }
            return expiresAt.timeIntervalSince(now) > Self.publicFreshnessWindow
        case .oneTime:
            return now.timeIntervalSince(entry.cachedAt) < Self.oneTimeCacheTTL
        }
    }

    private func needsPrewarm(for bookID: BookID, userID: UserID) -> Bool {
        let publicKey = PreparedCacheKey(userID: userID, bookID: bookID, access: .public)
        let oneTimeKey = PreparedCacheKey(userID: userID, bookID: bookID, access: .oneTime)
        guard let publicEntry = preparedCache[publicKey],
              let oneTimeEntry = preparedCache[oneTimeKey] else {
            return true
        }
        return !isFresh(publicEntry, access: .public) || !isFresh(oneTimeEntry, access: .oneTime)
    }

    private func prepareForAccount(
        bookIDs: [BookID],
        userID: UserID
    ) async throws -> SharePrepareResponse {
        let normalized = normalizedBookIDs(bookIDs)
        guard !normalized.isEmpty else {
            return SharePrepareResponse(links: [], skipped: [])
        }

        var links: [SharePreparedBook] = []
        var skipped: [SharePrepareSkippedBook] = []
        for chunk in normalized.chunked(maxCount: Self.prepareBatchLimit) {
            try Task.checkCancellation()
            let response = try await workerClient.send(
                SharePrepareEndpoint(body: .init(bookIDs: chunk.map(\.uuidString)))
            )
            guard await currentUserId() == userID else {
                throw ServiceError.accountChanged
            }
            guard activeUserID == userID else {
                throw ServiceError.accountChanged
            }

            links.append(contentsOf: response.links)
            skipped.append(contentsOf: response.skipped)
            for preparedBook in response.links {
                guard let bookID = BookID(uuidString: preparedBook.bookID) else { continue }
                guard normalized.contains(bookID) else { continue }
                let cachedAt = Date()
                preparedCache[PreparedCacheKey(userID: userID, bookID: bookID, access: .public)] =
                    PreparedCacheEntry(package: preparedBook.public, cachedAt: cachedAt)
                if !handedOutOneTimePackageIDs.contains(preparedBook.oneTime.id) {
                    preparedCache[PreparedCacheKey(userID: userID, bookID: bookID, access: .oneTime)] =
                        PreparedCacheEntry(package: preparedBook.oneTime, cachedAt: cachedAt)
                }
            }
            for skip in response.skipped {
                Log.event(
                    "sharing.prewarm.skipped",
                    data: ["book_id": skip.bookID, "reason": skip.code]
                )
            }
        }
        return SharePrepareResponse(links: links, skipped: skipped)
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: maxCount, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
