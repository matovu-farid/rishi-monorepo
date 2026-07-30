@testable import rishi
import Foundation
import Testing

@Suite("Chapter index coordinator", .serialized)
struct ChapterIndexCoordinatorTests {
    @Test("concurrent callers share one generation and a ready index avoids generation")
    func singleFlightAndReadyReuse() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let source = TestChapterSource(records: [chapter("c1"), chapter("c2")])
        let summarizer = CountingChapterSummarizer()
        let coordinator = ChapterIndexCoordinator(persistence: persistence, source: source, summarizer: summarizer, timeout: .seconds(2))

        let calls = try await withThrowingTaskGroup(of: ChapterIndex.self, returning: [ChapterIndex].self) { group in
            for _ in 0..<8 { group.addTask { try await coordinator.index(bookID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, contentVersion: "v1") } }
            var values: [ChapterIndex] = []
            for try await value in group { values.append(value) }
            return values
        }

        #expect(calls.allSatisfy { $0.status == .ready })
        #expect(await summarizer.callCount == 2)
        _ = try await coordinator.index(bookID: calls[0].bookID, contentVersion: "v1")
        #expect(await summarizer.callCount == 2)
    }

    @Test("timeout returns building without cancelling background generation")
    func timeoutDoesNotCancelGeneration() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let summarizer = BlockingChapterSummarizer()
        let coordinator = ChapterIndexCoordinator(persistence: persistence, source: TestChapterSource(records: [chapter("c1")]), summarizer: summarizer, timeout: .milliseconds(10))
        let bookID = UUID()

        let first = try await coordinator.index(bookID: bookID, contentVersion: "v1")
        #expect(first.status == .building)
        #expect(await summarizer.wasCancelled == false)

        await summarizer.release()
        let ready = try await coordinator.waitForCompletion(bookID: bookID, contentVersion: "v1")
        #expect(ready.status == .ready)
    }

    @Test("caller cancellation does not cancel shared generation")
    func cancellationLeavesGenerationAlive() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let summarizer = BlockingChapterSummarizer()
        let coordinator = ChapterIndexCoordinator(
            persistence: persistence,
            source: TestChapterSource(records: [chapter("c1")]),
            summarizer: summarizer,
            timeout: .seconds(10)
        )
        let bookID = UUID()
        let caller = Task {
            try await coordinator.index(bookID: bookID, contentVersion: "v1")
        }

        await Task.yield()
        caller.cancel()
        await #expect(throws: CancellationError.self) {
            try await caller.value
        }
        #expect(await summarizer.wasCancelled == false)

        await summarizer.release()
        let result = try await coordinator.waitForCompletion(bookID: bookID, contentVersion: "v1")
        #expect(result.status == .ready)
    }

    @Test("cancelling a completion waiter returns promptly without cancelling generation")
    func completionWaiterCancellationLeavesGenerationAlive() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let summarizer = BlockingChapterSummarizer()
        let coordinator = ChapterIndexCoordinator(
            persistence: persistence,
            source: TestChapterSource(records: [chapter("c1")]),
            summarizer: summarizer,
            timeout: .seconds(10)
        )
        let bookID = UUID()
        let waiter = Task {
            try await coordinator.waitForCompletion(bookID: bookID, contentVersion: "v1")
        }

        await Task.yield()
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await summarizer.wasCancelled == false)

        await summarizer.release()
        let ready = try await coordinator.waitForCompletion(bookID: bookID, contentVersion: "v1")
        #expect(ready.status == .ready)
    }

    @Test("resuming a persisted building index preserves its creation timestamp")
    func resumePreservesCreatedAt() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let bookID = UUID()
        let createdAt = Date(timeIntervalSince1970: 123)
        try await persistence.upsertChapterIndex(ChapterIndex(
            bookID: bookID,
            contentVersion: "v1",
            status: .building,
            modelIdentifier: "previous-model",
            modelVersion: "previous-version",
            progress: .init(completed: 1, total: 2),
            chapters: [.init(id: "c1", name: "c1", summary: "partial")],
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        let coordinator = ChapterIndexCoordinator(
            persistence: persistence,
            source: TestChapterSource(records: [chapter("c1")]),
            summarizer: CountingChapterSummarizer(),
            timeout: .seconds(2)
        )

        let result = try await coordinator.waitForCompletion(bookID: bookID, contentVersion: "v1")

        #expect(result.status == .ready)
        #expect(result.createdAt == createdAt)
    }

    @Test("partial source failures persist failed diagnostics instead of ready")
    func partialSourceFailureIsFailed() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let summarizer = CountingChapterSummarizer()
        let coordinator = ChapterIndexCoordinator(
            persistence: persistence,
            source: TestChapterSource(records: [chapter("c1")], availability: .partialFailure(diagnostics: ["chapter missing"])),
            summarizer: summarizer,
            timeout: .seconds(2)
        )

        let result = try await coordinator.waitForCompletion(bookID: UUID(), contentVersion: "v1")

        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("chapter missing") == true)
        #expect(result.status != .ready)
        #expect(await summarizer.callCount == 0)
    }

    @Test("unavailable source persists unavailable diagnostics instead of ready")
    func unavailableSourceIsUnavailable() async throws {
        let persistence = InMemoryChapterIndexPersistence()
        let coordinator = ChapterIndexCoordinator(
            persistence: persistence,
            source: TestChapterSource(records: [], availability: .unavailable(diagnostics: ["no outline"])),
            summarizer: CountingChapterSummarizer(),
            timeout: .seconds(2)
        )
        let bookID = UUID()

        let result = try await coordinator.waitForCompletion(bookID: bookID, contentVersion: "v1")
        let persisted = try await persistence.chapterIndex(bookID: bookID, contentVersion: "v1")

        #expect(result.status == .unavailable)
        #expect(result.errorMessage?.contains("no outline") == true)
        #expect(persisted?.status == .unavailable)
    }

    private func chapter(_ id: String) -> ChapterSourceRecord {
        ChapterSourceRecord(id: id, name: id, locator: .epub(href: "\(id).xhtml"), text: id)
    }
}

private actor InMemoryChapterIndexPersistence: ChapterIndexPersistence {
    var values: [String: ChapterIndex] = [:]
    func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? { values["\(bookID)-\(contentVersion)"] }
    func upsertChapterIndex(_ index: ChapterIndex) async throws { values["\(index.bookID)-\(index.contentVersion)"] = index }
}

private struct TestChapterSource: ChapterSource {
    let records: [ChapterSourceRecord]
    let availability: ChapterSourceResult.Availability
    init(records: [ChapterSourceRecord], availability: ChapterSourceResult.Availability = .available) {
        self.records = records
        self.availability = availability
    }
    func chapters() async -> ChapterSourceResult { ChapterSourceResult(availability: availability, records: records) }
}

private actor CountingChapterSummarizer: ChapterSummarizing {
    var callCount = 0
    func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary { callCount += 1; return .init(id: chapter.id, name: chapter.name, summary: chapter.text) }
}

private actor BlockingChapterSummarizer: ChapterSummarizing {
    var wasCancelled = false
    var released = false
    func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary {
        while !released {
            if Task.isCancelled { wasCancelled = true; throw CancellationError() }
            await Task.yield()
        }
        return .init(id: chapter.id, name: chapter.name, summary: chapter.text)
    }
    func release() { released = true }
}
