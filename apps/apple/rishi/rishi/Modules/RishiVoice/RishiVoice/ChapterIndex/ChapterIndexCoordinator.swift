import Foundation

public actor ChapterIndexCoordinator {
    private struct Key: Hashable, Sendable { let bookID: BookID; let contentVersion: String }
    private let persistence: any ChapterIndexPersistence
    private let source: any ChapterSource
    private let summarizer: any ChapterSummarizing
    private let timeout: Duration
    private let modelIdentifier: String
    private let modelVersion: String
    private var flights: [Key: Task<ChapterIndex, Error>] = [:]

    public init(persistence: any ChapterIndexPersistence, source: any ChapterSource, summarizer: any ChapterSummarizing, timeout: Duration = .seconds(1), modelIdentifier: String = "chapter-summarizer", modelVersion: String = "1") {
        self.persistence = persistence; self.source = source; self.summarizer = summarizer; self.timeout = timeout
        self.modelIdentifier = modelIdentifier; self.modelVersion = modelVersion
    }

    public func index(bookID: BookID, contentVersion: String) async throws -> ChapterIndex {
        let key = Key(bookID: bookID, contentVersion: contentVersion)
        let task = task(for: key)
        return try await valueUntilTimeout(task, bookID: bookID, contentVersion: contentVersion)
    }

    public func waitForCompletion(bookID: BookID, contentVersion: String) async throws -> ChapterIndex {
        let key = Key(bookID: bookID, contentVersion: contentVersion)
        let task = task(for: key)
        let race = ChapterIndexRace()
        Task {
            do {
                race.finish(.success(try await task.value))
            } catch {
                race.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// Reserves the key before the first await. This is the single-flight
    /// linearization point: every reentrant caller sees the same task handle.
    private func task(for key: Key) -> Task<ChapterIndex, Error> {
        if let task = flights[key] { return task }
        let initial = ChapterIndex(bookID: key.bookID, contentVersion: key.contentVersion, status: .building, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: 0, total: 0), chapters: [])
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.runGeneration(key: key, initial: initial)
        }
        flights[key] = task
        return task
    }

    private func runGeneration(key: Key, initial: ChapterIndex) async throws -> ChapterIndex {
        defer { flights[key] = nil }
        let persisted = try await persistence.chapterIndex(bookID: key.bookID, contentVersion: key.contentVersion)
        if let persisted, persisted.status == .ready || persisted.status == .failed || persisted.status == .unavailable {
            return persisted
        }
        let generation = ChapterIndex(
            bookID: initial.bookID,
            contentVersion: initial.contentVersion,
            status: .building,
            modelIdentifier: modelIdentifier,
            modelVersion: modelVersion,
            progress: .init(completed: 0, total: 0),
            chapters: [],
            createdAt: persisted?.createdAt ?? initial.createdAt
        )
        try await persistence.upsertChapterIndex(generation)
        let result = try await Self.generate(key: key, source: source, summarizer: summarizer, persistence: persistence, modelIdentifier: modelIdentifier, modelVersion: modelVersion, createdAt: generation.createdAt)
        if result.status != .building {
            try await persistence.markChapterIndexDirty(bookID: key.bookID)
        }
        return result
    }

    private func valueUntilTimeout(_ task: Task<ChapterIndex, Error>, bookID: BookID, contentVersion: String) async throws -> ChapterIndex {
        let building = ChapterIndex(bookID: bookID, contentVersion: contentVersion, status: .building, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: 0, total: 0), chapters: [])
        let race = ChapterIndexRace()

        // These are intentionally unstructured. The generation task is owned by
        // `flights` and must continue after this voice call reaches its deadline.
        Task {
            do {
                race.finish(.success(try await task.value))
            } catch {
                race.finish(.success(ChapterIndex(bookID: bookID, contentVersion: contentVersion, status: .failed, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: 0, total: 0), chapters: [], errorMessage: String(describing: error))))
            }
        }
        Task {
            do {
                try await Task.sleep(for: timeout)
                race.finish(.success(building))
            } catch {
                // Cancellation of the timeout waiter must not affect generation.
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private static func generate(key: Key, source: any ChapterSource, summarizer: any ChapterSummarizing, persistence: any ChapterIndexPersistence, modelIdentifier: String, modelVersion: String, createdAt: Date) async throws -> ChapterIndex {
        do {
            let result = await source.chapters()
            switch result.availability {
            case .partialFailure(let diagnostics):
                let failed = ChapterIndex(
                    bookID: key.bookID,
                    contentVersion: key.contentVersion,
                    status: .failed,
                    modelIdentifier: modelIdentifier,
                    modelVersion: modelVersion,
                    progress: .init(completed: 0, total: result.records.count),
                    chapters: [],
                    errorMessage: diagnostics.joined(separator: "\n"),
                    createdAt: createdAt
                )
                try await persistence.upsertChapterIndex(failed)
                return failed
            case .unavailable(let diagnostics):
                let unavailable = ChapterIndex(
                    bookID: key.bookID,
                    contentVersion: key.contentVersion,
                    status: .unavailable,
                    modelIdentifier: modelIdentifier,
                    modelVersion: modelVersion,
                    progress: .init(completed: 0, total: result.records.count),
                    chapters: [],
                    errorMessage: diagnostics.joined(separator: "\n"),
                    createdAt: createdAt
                )
                try await persistence.upsertChapterIndex(unavailable)
                return unavailable
            case .available:
                break
            }
            guard !result.records.isEmpty else {
                let unavailable = ChapterIndex(bookID: key.bookID, contentVersion: key.contentVersion, status: .unavailable, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: 0, total: 0), chapters: [], errorMessage: "No chapter structure is available", createdAt: createdAt)
                try await persistence.upsertChapterIndex(unavailable); return unavailable
            }
            var summaries: [ChapterIndexChapter] = []
            for (offset, chapter) in result.records.enumerated() {
                do {
                    let summary = try await summarizer.summarize(chapter: chapter)
                    summaries.append(.init(id: summary.id, name: summary.name, summary: summary.summary, sourcePosition: chapter.sourcePosition))
                    let progress = ChapterIndexProgress(completed: offset + 1, total: result.records.count)
                    try await persistence.upsertChapterIndex(.init(bookID: key.bookID, contentVersion: key.contentVersion, status: .building, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: progress, chapters: summaries, createdAt: createdAt))
                } catch {
                    let failed = ChapterIndex(bookID: key.bookID, contentVersion: key.contentVersion, status: .failed, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: summaries.count, total: result.records.count), chapters: summaries, errorMessage: String(describing: error), createdAt: createdAt)
                    try await persistence.upsertChapterIndex(failed); return failed
                }
            }
            let ready = ChapterIndex(bookID: key.bookID, contentVersion: key.contentVersion, status: .ready, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: summaries.count, total: summaries.count), chapters: summaries, createdAt: createdAt)
            try await persistence.upsertChapterIndex(ready); return ready
        } catch {
            let failed = ChapterIndex(bookID: key.bookID, contentVersion: key.contentVersion, status: .failed, modelIdentifier: modelIdentifier, modelVersion: modelVersion, progress: .init(completed: 0, total: 0), chapters: [], errorMessage: String(describing: error), createdAt: createdAt)
            try await persistence.upsertChapterIndex(failed); return failed
        }
    }

}

private final class ChapterIndexRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChapterIndex, Error>?
    private var result: Result<ChapterIndex, Error>?

    func install(_ continuation: CheckedContinuation<ChapterIndex, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<ChapterIndex, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            self.result = result
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }
}
