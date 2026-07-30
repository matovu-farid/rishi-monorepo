import Foundation

public struct ReaderSessionIdentity: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum CurrentPageContextAvailability: String, Codable, Sendable {
    case available
    case noText = "no_text"
    case unavailable
}

public struct CurrentPageContextResult: Codable, Equatable, Sendable {
    public let availability: CurrentPageContextAvailability
    public let page: Int?
    public let pageText: String?
    public let activeParagraphText: String?

    public init(
        availability: CurrentPageContextAvailability,
        page: Int? = nil,
        pageText: String? = nil,
        activeParagraphText: String? = nil
    ) {
        self.availability = availability
        self.page = page
        self.pageText = pageText
        self.activeParagraphText = activeParagraphText
    }

    private enum CodingKeys: String, CodingKey {
        case availability
        case page
        case pageText
        case activeParagraphText
    }

    /// Keep the tool result shape stable: optional values are explicit JSON
    /// nulls rather than disappearing keys, which makes no-text/unavailable
    /// responses unambiguous to the realtime model.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(availability, forKey: .availability)
        try container.encode(page, forKey: .page)
        try container.encode(pageText, forKey: .pageText)
        try container.encode(activeParagraphText, forKey: .activeParagraphText)
    }
}

public typealias CurrentPageContextProvider = @MainActor @Sendable () async throws -> CurrentPageContextResult
