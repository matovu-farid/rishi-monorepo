import Foundation

public struct LocalModelChapterSummarizerProvider: ChapterSummaryProvider {
    public typealias Availability = @Sendable () async -> Bool
    public typealias Invocation = @Sendable (ChapterSummaryRequest?, ChapterSummaryMergeRequest?) async throws -> Data

    private let availability: Availability
    private let invocation: Invocation

    public init(availability: @escaping Availability, invocation: @escaping Invocation) {
        self.availability = availability
        self.invocation = invocation
    }

    public func isAvailable() async -> Bool { await availability() }
    public func summarize(request: ChapterSummaryRequest) async throws -> Data { try await invocation(request, nil) }
    public func merge(request: ChapterSummaryMergeRequest) async throws -> Data { try await invocation(nil, request) }
}
