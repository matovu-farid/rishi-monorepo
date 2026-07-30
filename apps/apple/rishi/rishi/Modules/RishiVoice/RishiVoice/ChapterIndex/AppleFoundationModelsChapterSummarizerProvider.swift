import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macCatalyst 26.0, *)
public struct AppleFoundationModelsChapterSummarizerProvider: ChapterSummaryProvider, Sendable {
    public init() {}

    public func isAvailable() async -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func summarize(request: ChapterSummaryRequest) async throws -> Data {
        try await generateJSON(prompt: request.prompt)
    }

    public func merge(request: ChapterSummaryMergeRequest) async throws -> Data {
        try await generateJSON(prompt: request.prompt)
    }

    private func generateJSON(prompt: String) async throws -> Data {
        guard SystemLanguageModel.default.isAvailable else {
            throw LocalChapterSummaryError.modelUnavailable
        }

        let session = LanguageModelSession()
        let response = try await session.respond(to: """
        \(prompt)

        Output valid JSON only. Do not use Markdown fences or add any commentary.
        """)
        guard let data = response.content.data(using: .utf8) else {
            throw LocalChapterSummaryError.invalidResponse
        }
        return try JSONSerialization.normalizedObjectData(from: data)
    }
}

private enum LocalChapterSummaryError: Error, Sendable {
    case modelUnavailable
    case invalidResponse
}

private extension JSONSerialization {
    static func normalizedObjectData(from data: Data) throws -> Data {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw else { throw LocalChapterSummaryError.invalidResponse }

        let json = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try? jsonObject(with: Data(json.utf8), options: []) else {
            throw LocalChapterSummaryError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }
}
#endif
