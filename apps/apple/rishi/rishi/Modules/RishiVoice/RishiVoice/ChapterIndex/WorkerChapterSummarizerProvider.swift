import Foundation

public enum WorkerChapterSummarizerError: Error, Sendable, Equatable {
    case unavailable
}

public struct WorkerChapterSummaryBody: Encodable, Sendable, Equatable {
    public let operation: String
    public let chapterID: String
    public let chapterName: String
    public let input: String?
    public let sectionSummaries: [String]?
    public let prompt: String
    public let store: Bool

    public init(request: ChapterSummaryRequest) {
        operation = "summarize"
        chapterID = request.chapterID
        chapterName = request.chapterName
        input = request.input
        sectionSummaries = nil
        prompt = request.prompt
        store = false
    }

    public init(request: ChapterSummaryMergeRequest) {
        operation = "merge"
        chapterID = request.chapterID
        chapterName = request.chapterName
        input = nil
        sectionSummaries = request.sectionSummaries
        prompt = request.prompt
        store = false
    }
}

public struct WorkerChapterSummaryEndpoint: WorkerEndpointWithBody {
    public typealias Response = ChapterSummary
    public typealias Body = WorkerChapterSummaryBody

    public let method: HTTPMethod = .POST
    public let path = "/api/ai/chapter-summaries"
    public let requiresDataUseConsent = true
    public let body: WorkerChapterSummaryBody

    public init(request: ChapterSummaryRequest) { body = WorkerChapterSummaryBody(request: request) }
    public init(request: ChapterSummaryMergeRequest) { body = WorkerChapterSummaryBody(request: request) }
}

/// Authenticated Worker adapter for the eventual OpenAI proxy. WorkerClient
/// attaches the bearer token and current AI-data-consent header; Apple never
/// stores or sends an OpenAI key. The Worker route is intentionally not part
/// of this task.
public struct WorkerChapterSummarizerProvider: ChapterSummaryProvider {
    private let workerClient: WorkerClient

    public init(workerClient: WorkerClient) { self.workerClient = workerClient }

    public func isAvailable() async -> Bool {
        await workerClient.hasAuthenticatedAIRequestAccess()
    }

    public func summarize(request: ChapterSummaryRequest) async throws -> Data {
        guard await isAvailable() else { throw WorkerChapterSummarizerError.unavailable }
        return try JSONEncoder().encode(await workerClient.send(WorkerChapterSummaryEndpoint(request: request)))
    }

    public func merge(request: ChapterSummaryMergeRequest) async throws -> Data {
        guard await isAvailable() else { throw WorkerChapterSummarizerError.unavailable }
        return try JSONEncoder().encode(await workerClient.send(WorkerChapterSummaryEndpoint(request: request)))
    }
}
