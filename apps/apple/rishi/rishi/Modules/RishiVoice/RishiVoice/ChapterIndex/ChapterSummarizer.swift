import Foundation

public protocol ChapterSummaryProvider: Sendable {
    func isAvailable() async -> Bool
    func summarize(request: ChapterSummaryRequest) async throws -> Data
    func merge(request: ChapterSummaryMergeRequest) async throws -> Data
}

public struct ChapterSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String

    public init(id: String, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum ChapterSummaryValidationError: Error, Sendable, Equatable {
    case identityMismatch(expectedID: String, expectedName: String, actualID: String, actualName: String)
    case emptySummary
    case summaryTooLong(limit: Int)
}

public struct ChapterSummaryRequest: Sendable, Equatable {
    public let chapterID: String
    public let chapterName: String
    public let input: String
    public let prompt: String
    public let store: Bool

    public init(chapterID: String, chapterName: String, input: String, prompt: String, store: Bool) {
        self.chapterID = chapterID
        self.chapterName = chapterName
        self.input = input
        self.prompt = prompt
        self.store = store
    }
}

public struct ChapterSummaryMergeRequest: Sendable, Equatable {
    public let chapterID: String
    public let chapterName: String
    public let sectionSummaries: [String]
    public let prompt: String
    public let store: Bool

    public init(chapterID: String, chapterName: String, sectionSummaries: [String], prompt: String, store: Bool) {
        self.chapterID = chapterID
        self.chapterName = chapterName
        self.sectionSummaries = sectionSummaries
        self.prompt = prompt
        self.store = store
    }
}

public struct ChapterSummarizer: Sendable {
    public struct Configuration: Sendable, Equatable {
        public let maxInputCharacters: Int
        public let maxSummaryCharacters: Int

        public init(maxInputCharacters: Int = 12_000, maxSummaryCharacters: Int = 800) {
            self.maxInputCharacters = max(1, maxInputCharacters)
            self.maxSummaryCharacters = max(1, maxSummaryCharacters)
        }
    }

    private let local: (any ChapterSummaryProvider)?
    private let fallback: any ChapterSummaryProvider
    private let configuration: Configuration

    public init(local: (any ChapterSummaryProvider)?, fallback: any ChapterSummaryProvider, configuration: Configuration = .init()) {
        self.local = local
        self.fallback = fallback
        self.configuration = configuration
    }

    public func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary {
        let sections = boundedSections(chapter.text)
        if sections.count == 1 {
            return try await summarize(request: makeRequest(chapter: chapter, input: sections[0]))
        }
        var sectionSummaries: [String] = []
        sectionSummaries.reserveCapacity(sections.count)
        for section in sections {
            sectionSummaries.append(try await summarize(
                request: makeRequest(chapter: chapter, input: section)
            ).summary)
        }
        return try await merge(sectionSummaries: sectionSummaries, for: chapter)
    }

    public func merge(sectionSummaries: [String], for chapter: ChapterSourceRecord) async throws -> ChapterSummary {
        let request = ChapterSummaryMergeRequest(
            chapterID: chapter.id,
            chapterName: chapter.name,
            sectionSummaries: sectionSummaries,
            prompt: Self.mergePrompt(chapterName: chapter.name, sectionSummaries: sectionSummaries),
            store: false
        )
        return try await invoke(expectedID: chapter.id, expectedName: chapter.name) { provider in
            try await provider.merge(request: request)
        }
    }

    private func summarize(request: ChapterSummaryRequest) async throws -> ChapterSummary {
        try await invoke(expectedID: request.chapterID, expectedName: request.chapterName) { provider in
            try await provider.summarize(request: request)
        }
    }

    private func invoke(
        expectedID: String,
        expectedName: String,
        operation: (any ChapterSummaryProvider) async throws -> Data
    ) async throws -> ChapterSummary {
        if let local, await local.isAvailable() {
            do {
                return try validate(
                    ChapterSummary.decode(try await operation(local)),
                    expectedID: expectedID,
                    expectedName: expectedName
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
            }
        }
        return try validate(
            ChapterSummary.decode(try await operation(fallback)),
            expectedID: expectedID,
            expectedName: expectedName
        )
    }

    private func validate(
        _ result: ChapterSummary,
        expectedID: String,
        expectedName: String
    ) throws -> ChapterSummary {
        guard result.id == expectedID, result.name == expectedName else {
            throw ChapterSummaryValidationError.identityMismatch(
                expectedID: expectedID,
                expectedName: expectedName,
                actualID: result.id,
                actualName: result.name
            )
        }
        guard !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChapterSummaryValidationError.emptySummary
        }
        guard result.summary.count <= configuration.maxSummaryCharacters else {
            throw ChapterSummaryValidationError.summaryTooLong(limit: configuration.maxSummaryCharacters)
        }
        return result
    }

    private func makeRequest(chapter: ChapterSourceRecord, input: String) -> ChapterSummaryRequest {
        ChapterSummaryRequest(
            chapterID: chapter.id,
            chapterName: chapter.name,
            input: input,
            prompt: Self.summaryPrompt(chapterName: chapter.name, input: input),
            store: false
        )
    }

    private func boundedSections(_ text: String) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [""] }
        return stride(from: 0, to: characters.count, by: configuration.maxInputCharacters).map { start in
            String(characters[start..<min(start + configuration.maxInputCharacters, characters.count)])
        }
    }

    private static func summaryPrompt(chapterName: String, input: String) -> String {
        """
        Summarize the chapter section factually and concisely.
        Chapter: \(chapterName)
        Section text:
        \(input)
        Return only JSON with exactly the keys id, name, and summary.
        """
    }

    private static func mergePrompt(chapterName: String, sectionSummaries: [String]) -> String {
        """
        Merge these factual section summaries into one concise chapter summary.
        Chapter: \(chapterName)
        Section summaries:
        \(sectionSummaries.joined(separator: "\n"))
        Return only JSON with exactly the keys id, name, and summary.
        """
    }
}
