import Foundation

private final class IndexingTaskRegistry: @unchecked Sendable {
    private struct Owner: Hashable {
        let id: UserID
        let generation: UInt64
    }

    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        let sourceInstanceID: UUID?
    }

    enum Start {
        case running(Task<Void, Never>)
        case cancelled(UUID, Task<Void, Never>)
        case rejected
    }

    private let lock = NSLock()
    private var tasks: [BookIndexingIdentity: Entry] = [:]
    private var blockedBooks: Set<BookIndexingIdentity> = []
    private var blockedOwners: Set<Owner> = []

    /// Source admission and task insertion share one synchronous critical
    /// section. Retirement closes source authority before cancelling here.
    func start(
        identity: BookIndexingIdentity,
        source: BookIndexingSource?,
        operation: @escaping @Sendable () async -> Void
    ) -> Start {
        lock.lock()
        defer { lock.unlock() }
        let owner = Owner(id: identity.ownerID, generation: identity.generation)
        let admission: SourceEffectAdmission?
        if let source {
            guard let admitted = try? source.lease.effectAuthority.admit(source.lease.sourceAccessPermit) else { return .rejected }
            admission = admitted
        } else {
            guard !blockedBooks.contains(identity), !blockedOwners.contains(owner) else { return .rejected }
            admission = nil
        }
        if let existing = tasks[identity] {
            admission?.release()
            return existing.task.isCancelled ? .cancelled(existing.id, existing.task) : .running(existing.task)
        }
        // A new admitted source is proof of authorized source rollback. Old
        // permits remain closed and cannot reopen a retired indexing key.
        if source != nil {
            blockedBooks.remove(identity)
            blockedOwners.remove(owner)
        }
        let id = UUID()
        let task = Task.detached(priority: .background) {
            defer { admission?.release(); withExtendedLifetime(source) {} }
            await operation()
        }
        tasks[identity] = Entry(id: id, task: task, sourceInstanceID: source?.lease.sourceAccessPermit.sourceInstanceID)
        Task { [weak self] in
            await task.value
            self?.remove(identity: identity, id: id)
        }
        return .running(task)
    }

    func remove(identity: BookIndexingIdentity, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard tasks[identity]?.id == id else { return }
        tasks[identity] = nil
    }

    func cancelBook(_ identity: BookIndexingIdentity) {
        lock.lock()
        defer { lock.unlock() }
        blockedBooks.insert(identity)
        tasks[identity]?.task.cancel()
    }

    func cancelOwner(ownerID: UserID, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        blockedOwners.insert(Owner(id: ownerID, generation: generation))
        for (identity, entry) in tasks where identity.ownerID == ownerID && identity.generation == generation {
            blockedBooks.insert(identity)
            entry.task.cancel()
        }
    }

    func drainBook(_ identity: BookIndexingIdentity) async {
        let entry = bookEntry(identity)
        await entry?.task.value
        if let entry { remove(identity: identity, id: entry.id) }
    }

    func drainOwner(ownerID: UserID, generation: UInt64) async {
        let entries = ownerEntries(ownerID: ownerID, generation: generation)
        for (identity, entry) in entries {
            await entry.task.value
            remove(identity: identity, id: entry.id)
        }
    }

    private func bookEntry(_ identity: BookIndexingIdentity) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[identity]
    }

    private func ownerEntries(ownerID: UserID, generation: UInt64) -> [BookIndexingIdentity: Entry] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.key.ownerID == ownerID && $0.key.generation == generation }
    }
}

/// Owns each actual extraction/index writer through persistence and callback.
/// Retirement requests cancellation; drain waits for genuinely entered work.
public final class RishiSearchIndexingHook: AwaitableBookIndexingHook, @unchecked Sendable {
    private let builder: IndexBuilder
    private let extractors: [String: any PerBookTextExtractor]
    private let onIndexReady: (@Sendable (UUID) async -> Void)?
    private let acquireSource: (@Sendable (Book) async throws -> BookIndexingSource)?
    private let inFlightTasks = IndexingTaskRegistry()

    public init(
        builder: IndexBuilder,
        extractors: [String: any PerBookTextExtractor],
        onIndexReady: (@Sendable (UUID) async -> Void)? = nil,
        acquireSource: (@Sendable (Book) async throws -> BookIndexingSource)? = nil
    ) {
        self.builder = builder
        self.extractors = extractors
        self.onIndexReady = onIndexReady
        self.acquireSource = acquireSource
    }

    public func cancelBook(ownerID: UserID, generation: UInt64, bookID: BookID) {
        inFlightTasks.cancelBook(BookIndexingIdentity(ownerID: ownerID, generation: generation, bookID: bookID))
    }

    public func cancelOwner(ownerID: UserID, generation: UInt64) {
        inFlightTasks.cancelOwner(ownerID: ownerID, generation: generation)
    }

    public func drainBook(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        await inFlightTasks.drainBook(BookIndexingIdentity(ownerID: ownerID, generation: generation, bookID: bookID))
    }

    public func drainOwner(ownerID: UserID, generation: UInt64) async {
        await inFlightTasks.drainOwner(ownerID: ownerID, generation: generation)
    }

    public func scheduleIndexing(for book: Book, fileURL: URL) async {
        _ = await startIndexing(for: book, fileURL: fileURL)
    }

    public func scheduleIndexingAndWait(for book: Book, fileURL: URL) async {
        guard let task = await startIndexing(for: book, fileURL: fileURL) else { return }
        await task.value
    }

    private func startIndexing(for book: Book, fileURL: URL) async -> Task<Void, Never>? {
        while !Task.isCancelled {
            let source: BookIndexingSource?
            if let acquireSource {
                guard let acquired = try? await acquireSource(book),
                      acquired.identity.ownerID == book.userId,
                      acquired.identity.bookID == book.id,
                      acquired.lease.url.standardizedFileURL == fileURL.standardizedFileURL,
                      case let .account(permit) = acquired.lease.access,
                      permit.ownerID == acquired.identity.ownerID,
                      permit.accountGeneration == acquired.identity.generation,
                      permit.bookID == book.id,
                      case let .managed(managedID, _) = acquired.lease.cachePolicy,
                      managedID == book.id, !Task.isCancelled else { return nil }
                source = acquired
            } else {
                source = nil
            }
            let identity = source?.identity ?? BookIndexingIdentity(ownerID: book.userId, generation: 0, bookID: book.id)
            let result = inFlightTasks.start(identity: identity, source: source, operation: makeOperation(book: book, fileURL: fileURL))
            switch result {
            case .running(let task): return task
            case .rejected: return nil
            case .cancelled(let id, let task):
                // A rollback may authorize a fresh source, but it cannot
                // overlap the canceled writer. Reacquire proof after joining.
                await task.value
                inFlightTasks.remove(identity: identity, id: id)
            }
        }
        return nil
    }

    private func makeOperation(book: Book, fileURL: URL) -> @Sendable () async -> Void {
        let ext = fileURL.pathExtension.lowercased()
        let bookID = book.id
        let builder = self.builder
        let extractor = extractors[ext]
        let onIndexReady = self.onIndexReady
        return {
            do {
                try Task.checkCancellation()
                guard let extractor else {
                    Log.event("rag.index.no_extractor", level: .warning, data: ["bookId": bookID.uuidString, "ext": ext])
                    await builder.markFailed(bookId: bookID, reason: "no extractor for .\(ext)")
                    return
                }
                await builder.markIndexing(bookId: bookID)
                try Task.checkCancellation()
                let paragraphs = try await extractor.extractParagraphs(from: fileURL)
                try Task.checkCancellation()
                if paragraphs.isEmpty {
                    Log.event("rag.index.empty_paragraphs", level: .warning, data: ["bookId": bookID.uuidString])
                }
                try await builder.buildIndex(bookId: bookID, paragraphs: paragraphs)
                try Task.checkCancellation()
                await onIndexReady?(bookID)
                Log.event("rag.index.scheduled.done", level: .info, data: ["bookId": bookID.uuidString, "paragraphs": String(paragraphs.count)])
            } catch is CancellationError {
                Log.event("rag.index.cancelled", level: .info, data: ["bookId": bookID.uuidString])
            } catch {
                guard !Task.isCancelled else { return }
                Log.event("rag.index.scheduled.failed", level: .error, data: ["bookId": bookID.uuidString, "error": String(describing: error)])
                await builder.markFailed(bookId: bookID, reason: String(describing: error))
            }
        }
    }
}
