import Foundation


/// Resolves cover-image URLs for library books, owning the HEIC-cache
/// fast/slow decision and the concurrent fan-out that the library grid
/// depends on.
///
/// Extracted from `LibraryViewModel.refresh()` / `LibraryViewModel.coverURL`
/// (Plan 34-11) so the view-model no longer performs storage orchestration.
/// The single fast-then-slow rule — previously duplicated in the VM's
/// `refresh()` task body AND its `coverURL(for:)` helper — now lives in
/// exactly one place (`coverURL(for:)` below); the fan-out reuses it.
///
/// Resolution order per book:
///   1. `BookFileStorage.cachedCoverURLIfFresh` — nonisolated HEIC-cache
///      fast path; returns instantly when the downsampled HEIC + mtime
///      sidecar are present and fresh, paying only a stat syscall on the
///      cooperative executor.
///   2. `BookFileStorage.cachedCoverURL(for:)` — slow path that lazily warms
///      the HEIC cache from the on-disk `cover.png` and returns the cache
///      URL. This is what makes newly-imported books render their cover on
///      the very next paint — locked by
///      `LibraryViewModelImportCoverRegressionTests`.
///
/// Books that have no `cover.png` on disk resolve to `nil` and are absent
/// from the returned map (the grid renders the gradient fallback).
public struct BookCoverResolver: Sendable {

    private let storage: BookFileStorage?
    private let resolveOverride: (@Sendable (Book) async -> URL?)?
    private let managedReadiness: (@Sendable (Book) async -> Bool)?
    private let artworkReadAllowed: (@Sendable (Book) async -> Bool)?
    private let workLimiter: CoverWorkLimiter

    public init(
        storage: BookFileStorage,
        isManagedReady: (@Sendable (Book) async -> Bool)? = nil,
        isArtworkReadAllowed: (@Sendable (Book) async -> Bool)? = nil
    ) {
        self.storage = storage
        self.resolveOverride = nil
        self.managedReadiness = isManagedReady
        self.artworkReadAllowed = isArtworkReadAllowed
        self.workLimiter = CoverWorkLimiter(limit: 4)
    }

    /// Allows callers with a separate cover source to provide the same
    /// asynchronous resolution contract. Production storage composition uses
    /// `init(storage:)`; the closure is also useful for deterministic
    /// publication tests.
    init(
        resolve: @escaping @Sendable (Book) async -> URL?,
        isManagedReady: (@Sendable (Book) async -> Bool)? = nil,
        isArtworkReadAllowed: (@Sendable (Book) async -> Bool)? = nil
    ) {
        self.storage = nil
        self.resolveOverride = resolve
        self.managedReadiness = isManagedReady
        self.artworkReadAllowed = isArtworkReadAllowed
        self.workLimiter = CoverWorkLimiter(limit: 4)
    }

    /// Resolves a single book's cover URL using the fast-then-slow rule.
    /// This is the one place the fast/slow decision is made.
    public func coverURL(for book: Book) async -> URL? {
        if let artworkReadAllowed, !(await artworkReadAllowed(book)) { return nil }
        if artworkReadAllowed != nil, let storage {
            do {
                if let artwork = try await storage.existingArtworkURL(for: book) {
                    guard !Task.isCancelled,
                          await artworkReadAllowed?(book) == true else { return nil }
                    return artwork
                }
            } catch {
                return nil
            }
        }
        if let managedReadiness, !(await managedReadiness(book)) { return nil }
        if let resolveOverride {
            let result = await resolveOverride(book)
            guard !Task.isCancelled else { return nil }
            if let artworkReadAllowed, !(await artworkReadAllowed(book)) { return nil }
            return result
        }
        guard let storage else { return nil }
        if let warm = storage.cachedCoverURLIfFresh(for: book) {
            guard !Task.isCancelled else { return nil }
            if let artworkReadAllowed, !(await artworkReadAllowed(book)) { return nil }
            return warm
        }
        let result = await storage.cachedCoverURL(for: book)
        guard !Task.isCancelled else { return nil }
        if let artworkReadAllowed, !(await artworkReadAllowed(book)) { return nil }
        return result
    }

    /// Resolves covers with a fixed concurrency bound. The priority callback
    /// is consulted whenever a worker slot opens, so newly visible books move
    /// ahead of pending background work. `onResolved` receives nil explicitly
    /// when a book has no cover, allowing callers to merge only that ID.
    @MainActor
    func resolveCoverURLs(
        for books: [Book],
        excluding excludedBookIDs: Set<BookID> = [],
        maxConcurrent: Int = 4,
        prioritizedBookIDs: @escaping @MainActor @Sendable () -> Set<BookID>,
        onResolved: @escaping @MainActor @Sendable (BookID, URL?) -> Void,
        onScheduled: @escaping @MainActor @Sendable (BookID) -> Void = { _ in }
    ) async {
        let pending = books.filter { !excludedBookIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        let limit = min(4, max(1, maxConcurrent))
        let queue = PendingCoverQueue(books: pending, priority: prioritizedBookIDs, onScheduled: onScheduled)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<limit {
                group.addTask { [self] in
                    while !Task.isCancelled {
                        guard await resolveNextCover(from: queue, onResolved: onResolved) else { return }
                    }
                }
            }
        }
    }

    private func resolveNextCover(
        from queue: PendingCoverQueue,
        onResolved: @MainActor @Sendable (BookID, URL?) -> Void
    ) async -> Bool {
        let acquiredPermit = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await workLimiter.acquirePermit() }
            group.addTask {
                await queue.waitUntilEmpty()
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            if !result {
                for await didAcquire in group where didAcquire {
                    await workLimiter.releasePermit()
                }
                return false
            }
            for await _ in group {}
            return true
        }
        guard acquiredPermit else { return false }
        guard !Task.isCancelled else {
            await workLimiter.releasePermit()
            return false
        }
        guard let book = await queue.takeNext() else {
            await workLimiter.releasePermit()
            return false
        }
        guard !Task.isCancelled else {
            await workLimiter.releasePermit()
            return false
        }
        let url = await coverURL(for: book)
        guard !Task.isCancelled else {
            await workLimiter.releasePermit()
            return false
        }
        await onResolved(book.id, url)
        await workLimiter.releasePermit()
        return true
    }

    func waitForQueuedCoverJobs(_ count: Int) async {
        await workLimiter.waitForQueuedJobs(count)
    }

    func coverWorkCounts() async -> (active: Int, queued: Int) {
        await workLimiter.counts()
    }

    /// Compatibility full-map API for non-UI consumers. It collects the same
    /// bounded resolver results and omits nil values as before.
    public func coverURLs(for books: [Book], excluding excludedBookIDs: Set<BookID> = []) async -> [BookID: URL] {
        await collectCoverURLs(for: books, excluding: excludedBookIDs)
    }

    @MainActor
    private func collectCoverURLs(for books: [Book], excluding excludedBookIDs: Set<BookID>) async -> [BookID: URL] {
        var results: [BookID: URL] = [:]
        await resolveCoverURLs(
            for: books,
            excluding: excludedBookIDs,
            prioritizedBookIDs: { [] },
            onResolved: { id, url in if let url { results[id] = url } }
        )
        return results
    }
}

@MainActor
private final class PendingCoverQueue {
    private var books: [Book]
    private let priority: @MainActor @Sendable () -> Set<BookID>
    private let onScheduled: @MainActor @Sendable (BookID) -> Void
    private var emptyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        books: [Book],
        priority: @escaping @MainActor @Sendable () -> Set<BookID>,
        onScheduled: @escaping @MainActor @Sendable (BookID) -> Void
    ) {
        self.books = books
        self.priority = priority
        self.onScheduled = onScheduled
    }

    func takeNext() -> Book? {
        guard !books.isEmpty else { return nil }
        let priorityIDs = priority()
        let index = books.firstIndex(where: { priorityIDs.contains($0.id) }) ?? 0
        let book = books.remove(at: index)
        onScheduled(book.id)
        if books.isEmpty {
            let waiters = emptyWaiters.values
            emptyWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return book
    }

    func waitUntilEmpty() async {
        guard !books.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || books.isEmpty {
                    continuation.resume()
                } else {
                    emptyWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelEmptyWaiter(id) }
        }
    }

    private func cancelEmptyWaiter(_ id: UUID) {
        emptyWaiters.removeValue(forKey: id)?.resume()
    }
}

private actor CoverWorkLimiter {
    private let limit: Int
    private var active = 0
    private var queue: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var thresholdWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(limit: Int) { self.limit = limit }

    func counts() -> (active: Int, queued: Int) { (active, waiters.count) }

    func waitForQueuedJobs(_ count: Int) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { thresholdWaiters.append((count, $0)) }
    }

    func acquirePermit() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    queue.append(id)
                    waiters[id] = continuation
                    resumeThresholdWaitersIfReady()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func releasePermit() {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let continuation = waiters.removeValue(forKey: id) else { continue }
            // Transfer the permit without decrementing `active`.
            continuation.resume(returning: true)
            resumeThresholdWaitersIfReady()
            return
        }
        active -= 1
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        continuation.resume(returning: false)
        resumeThresholdWaitersIfReady()
    }

    private func resumeThresholdWaitersIfReady() {
        let ready = thresholdWaiters.filter { waiters.count >= $0.0 }
        thresholdWaiters.removeAll { waiters.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}
