import Foundation

private actor IndexingTaskRegistry {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [UUID: Entry] = [:]

    func task(
        for bookID: UUID,
        markIndexing: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async -> Void
    ) async -> Task<Void, Never> {
        if let existing = tasks[bookID] { return existing.task }

        // The actor can re-enter while the sidecar write is awaited. Check
        // again after it returns so simultaneous readers still join one task.
        await markIndexing()
        if let existing = tasks[bookID] { return existing.task }

        let id = UUID()
        let task = Task.detached(priority: .background) { await operation() }
        tasks[bookID] = Entry(id: id, task: task)
        Task { [weak self] in
            await task.value
            await self?.remove(bookID: bookID, id: id)
        }
        return task
    }

    private func remove(bookID: UUID, id: UUID) {
        guard tasks[bookID]?.id == id else { return }
        tasks.removeValue(forKey: bookID)
    }
}

/// Production `BookIndexingHook` conformer that wires `IndexBuilder` to a
/// per-format `PerBookTextExtractor`. Fire-and-forget import callers use
/// `scheduleIndexing`; reader callers can join the actual task through
/// `scheduleIndexingAndWait` and retain a source admission through persistence.
public final class RishiSearchIndexingHook: AwaitableBookIndexingHook, @unchecked Sendable {
    private let builder: IndexBuilder
    private let extractors: [String: any PerBookTextExtractor]
    private let onIndexReady: (@Sendable (UUID) async -> Void)?
    private let inFlightTasks = IndexingTaskRegistry()

    public init(
        builder: IndexBuilder,
        extractors: [String: any PerBookTextExtractor],
        onIndexReady: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.builder = builder
        self.extractors = extractors
        self.onIndexReady = onIndexReady
    }

    public func scheduleIndexing(for book: Book, fileURL: URL) async {
        _ = await startIndexing(for: book, fileURL: fileURL)
    }

    public func scheduleIndexingAndWait(for book: Book, fileURL: URL) async {
        guard let task = await startIndexing(for: book, fileURL: fileURL) else { return }
        await task.value
    }

    private func startIndexing(for book: Book, fileURL: URL) async -> Task<Void, Never>? {
        let ext = fileURL.pathExtension.lowercased()
        let bookID = book.id
        guard let extractor = extractors[ext] else {
            Log.event("rag.index.no_extractor", level: .warning, data: [
                "bookId": bookID.uuidString,
                "ext": ext,
            ])
            // No extractor means no build task will exist to move the sidecar
            // out of .notIndexed. Record a terminal failure synchronously.
            await builder.markFailed(bookId: bookID, reason: "no extractor for .\(ext)")
            return nil
        }

        let builder = self.builder
        let onIndexReady = self.onIndexReady
        return await inFlightTasks.task(
            for: bookID,
            markIndexing: { await builder.markIndexing(bookId: bookID) },
            operation: {
                do {
                    let paragraphs = try await extractor.extractParagraphs(from: fileURL)
                    if paragraphs.isEmpty {
                        Log.event("rag.index.empty_paragraphs", level: .warning, data: [
                            "bookId": bookID.uuidString,
                        ])
                    }
                    // Empty books still persist a valid ready index. For all
                    // inputs, returning from buildIndex means persistence and
                    // the terminal status write have completed.
                    try await builder.buildIndex(bookId: bookID, paragraphs: paragraphs)
                    await onIndexReady?(bookID)
                    Log.event("rag.index.scheduled.done", level: .info, data: [
                        "bookId": bookID.uuidString,
                        "paragraphs": String(paragraphs.count),
                    ])
                } catch {
                    Log.event("rag.index.scheduled.failed", level: .error, data: [
                        "bookId": bookID.uuidString,
                        "error": String(describing: error),
                    ])
                    // The throw happened before buildIndex could write the
                    // sidecar, so mark a terminal result before task completion.
                    await builder.markFailed(bookId: bookID, reason: String(describing: error))
                }
            }
        )
    }
}
