@testable import rishi
import Foundation
import Testing

@Suite("Chapter summarizer", .serialized)
struct ChapterSummarizerTests {

    @Test("selects an available local provider")
    func selectsLocalProvider() async throws {
        let local = FakeChapterSummaryProvider(available: true, summary: summary("local"))
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("remote"))
        let summarizer = ChapterSummarizer(local: local, fallback: fallback)

        let result = try await summarizer.summarize(chapter: chapter(text: "Short chapter"))

        #expect(result.summary == "local")
        #expect(await local.summarizeCallCount == 1)
        #expect(await fallback.summarizeCallCount == 0)
    }

    @Test("falls back when local provider is unavailable")
    func fallsBackWhenLocalUnavailable() async throws {
        let local = FakeChapterSummaryProvider(available: false, summary: summary("local"))
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("remote"))
        let summarizer = ChapterSummarizer(local: local, fallback: fallback)

        let result = try await summarizer.summarize(chapter: chapter(text: "Short chapter"))

        #expect(result.summary == "remote")
        #expect(await local.summarizeCallCount == 0)
        #expect(await fallback.summarizeCallCount == 1)
    }

    @Test("falls back after a local invocation failure")
    func fallsBackAfterLocalFailure() async throws {
        let local = FakeChapterSummaryProvider(
            available: true,
            summary: summary("local"),
            error: TestError.failed
        )
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("remote"))
        let summarizer = ChapterSummarizer(local: local, fallback: fallback)

        let result = try await summarizer.summarize(chapter: chapter(text: "Short chapter"))

        #expect(result.summary == "remote")
        #expect(await fallback.summarizeCallCount == 1)
    }

    @Test("does not fall back when local invocation is cancelled")
    func cancellationDoesNotFallBack() async throws {
        let local = FakeChapterSummaryProvider(available: true, summary: summary("local"), error: CancellationError())
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("remote"))
        let summarizer = ChapterSummarizer(local: local, fallback: fallback)

        await #expect(throws: CancellationError.self) {
            try await summarizer.summarize(chapter: chapter(text: "Short chapter"))
        }
        #expect(await fallback.summarizeCallCount == 0)
    }

    @Test("does not fall back after the summarization task is cancelled")
    func cancelledTaskDoesNotFallBack() async throws {
        let local = CancellableChapterSummaryProvider()
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("remote"))
        let summarizer = ChapterSummarizer(local: local, fallback: fallback)
        let task = Task {
            try await summarizer.summarize(chapter: chapter(text: "Short chapter"))
        }

        await Task.yield()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await fallback.summarizeCallCount == 0)
    }

    @Test("rejects a provider result for another chapter")
    func rejectsMismatchedIdentity() async throws {
        let wrong = ChapterSummary(id: "chapter-2", name: "Chapter 2", summary: "wrong")
        let fallback = FakeChapterSummaryProvider(available: true, summary: wrong)
        let summarizer = ChapterSummarizer(local: nil, fallback: fallback)

        await #expect(throws: ChapterSummaryValidationError.self) {
            try await summarizer.summarize(chapter: chapter(text: "Short chapter"))
        }
    }

    @Test("rejects an overlong provider result")
    func rejectsOverlongSummary() async throws {
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("123456789"))
        let summarizer = ChapterSummarizer(
            local: nil,
            fallback: fallback,
            configuration: .init(maxSummaryCharacters: 8)
        )

        await #expect(throws: ChapterSummaryValidationError.self) {
            try await summarizer.summarize(chapter: chapter(text: "Short chapter"))
        }
    }

    @Test("uses deterministic prompts and bounded section batches")
    func usesDeterministicBoundedPrompts() async throws {
        let local = FakeChapterSummaryProvider(available: false, summary: summary("local"))
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("remote"))
        let summarizer = ChapterSummarizer(
            local: local,
            fallback: fallback,
            configuration: .init(maxInputCharacters: 8)
        )
        let input = chapter(text: "12345678ABCDEFGH")

        _ = try await summarizer.summarize(chapter: input)

        let requests = await fallback.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.input.count <= 8 })
        let firstRequest = try #require(requests.first)
        let secondRequest = try #require(requests.dropFirst().first)
        #expect(firstRequest.prompt == secondRequest.prompt.replacingOccurrences(of: "ABCDEFGH", with: "12345678"))
        #expect(requests.allSatisfy { $0.store == false })
        #expect(requests.allSatisfy { $0.prompt.contains("Return only JSON") })
        #expect(await fallback.mergeRequests.count == 1)
    }

    @Test("merges section summaries through the same structured result type")
    func mergesSectionSummaries() async throws {
        let fallback = FakeChapterSummaryProvider(available: true, summary: summary("merged"))
        let summarizer = ChapterSummarizer(local: nil, fallback: fallback)
        let input = chapter(text: "ignored")

        let result = try await summarizer.merge(
            sectionSummaries: ["First event", "Second event"],
            for: input
        )

        #expect(result == summary("merged"))
        let request = try #require(await fallback.mergeRequests.first)
        #expect(request.sectionSummaries == ["First event", "Second event"])
        #expect(request.store == false)
    }

    @Test("Worker fallback requires bearer auth and current AI consent")
    func workerFallbackRequiresAuthAndConsent() async throws {
        let authenticatedClient = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider("session-token"),
            dataUseConsentProvider: TestConsentProvider(value: true)
        )
        let provider = WorkerChapterSummarizerProvider(workerClient: authenticatedClient)
        #expect(await provider.isAvailable())
        let request = try await authenticatedClient.buildRequest(
            for: WorkerChapterSummaryEndpoint(request: ChapterSummaryRequest(
                chapterID: "chapter-1", chapterName: "Chapter 1", input: "text", prompt: "prompt", store: false
            ))
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(request.value(forHTTPHeaderField: WorkerDataUseConsent.headerField) == WorkerDataUseConsent.currentVersion)

        let noToken = WorkerChapterSummarizerProvider(workerClient: WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider(nil),
            dataUseConsentProvider: TestConsentProvider(value: true)
        ))
        let noConsent = WorkerChapterSummarizerProvider(workerClient: WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider("session-token"),
            dataUseConsentProvider: TestConsentProvider(value: false)
        ))
        #expect(await noToken.isAvailable() == false)
        #expect(await noConsent.isAvailable() == false)
    }

    @Test("decodes a structured provider response")
    func decodesStructuredResponse() throws {
        let data = Data(#"{"id":"chapter-1","name":"Chapter 1","summary":"A concise result"}"#.utf8)
        #expect(try ChapterSummary.decode(data) == ChapterSummary(
            id: "chapter-1",
            name: "Chapter 1",
            summary: "A concise result"
        ))
    }

    private func chapter(text: String) -> ChapterSourceRecord {
        ChapterSourceRecord(
            id: "chapter-1",
            name: "Chapter 1",
            locator: .epub(href: "chapter-1.xhtml"),
            text: text
        )
    }

    private func summary(_ text: String) -> ChapterSummary {
        ChapterSummary(id: "chapter-1", name: "Chapter 1", summary: text)
    }
}

private actor FakeChapterSummaryProvider: ChapterSummaryProvider {
    let available: Bool
    let response: ChapterSummary
    let error: Error?
    private(set) var summarizeCallCount = 0
    private(set) var requests: [ChapterSummaryRequest] = []
    private(set) var mergeRequests: [ChapterSummaryMergeRequest] = []

    init(available: Bool, summary: ChapterSummary, error: Error? = nil) {
        self.available = available
        response = summary
        self.error = error
    }

    func isAvailable() async -> Bool { available }

    func summarize(request: ChapterSummaryRequest) async throws -> Data {
        summarizeCallCount += 1
        requests.append(request)
        if let error { throw error }
        return try JSONEncoder().encode(response)
    }

    func merge(request: ChapterSummaryMergeRequest) async throws -> Data {
        mergeRequests.append(request)
        if let error { throw error }
        return try JSONEncoder().encode(response)
    }
}

private actor CancellableChapterSummaryProvider: ChapterSummaryProvider {
    func isAvailable() async -> Bool { true }

    func summarize(request: ChapterSummaryRequest) async throws -> Data {
        while !Task.isCancelled {
            await Task.yield()
        }
        throw CancellationError()
    }

    func merge(request: ChapterSummaryMergeRequest) async throws -> Data {
        throw CancellationError()
    }
}

private struct TestConsentProvider: WorkerDataUseConsentProvider {
    let value: Bool
    func hasCurrentDataUseConsent() async -> Bool { value }
}

private enum TestError: Error, Sendable {
    case failed
}
