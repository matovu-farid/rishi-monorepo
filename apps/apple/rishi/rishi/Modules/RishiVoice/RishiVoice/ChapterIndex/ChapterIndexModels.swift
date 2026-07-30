import Foundation

public enum ChapterIndexStatus: String, Codable, Sendable, Equatable { case building, ready, unavailable, failed }

public struct ChapterIndexProgress: Codable, Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public init(completed: Int, total: Int) { self.completed = max(0, completed); self.total = max(0, total) }
}

public struct ChapterIndexChapter: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let sourcePosition: Int

    public init(id: String, name: String, summary: String, sourcePosition: Int = 0) {
        self.id = id
        self.name = name
        self.summary = summary
        self.sourcePosition = sourcePosition
    }

    private enum CodingKeys: String, CodingKey { case id, name, summary, sourcePosition }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        sourcePosition = try container.decodeIfPresent(Int.self, forKey: .sourcePosition) ?? 0
    }
}

public struct ChapterIndex: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let bookID: BookID
    public let contentVersion: String
    public let status: ChapterIndexStatus
    public let modelIdentifier: String
    public let modelVersion: String
    public let progress: ChapterIndexProgress
    public let chapters: [ChapterIndexChapter]
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID = UUID(), bookID: BookID, contentVersion: String, status: ChapterIndexStatus, modelIdentifier: String, modelVersion: String, progress: ChapterIndexProgress, chapters: [ChapterIndexChapter], errorMessage: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.bookID = bookID; self.contentVersion = contentVersion; self.status = status
        self.modelIdentifier = modelIdentifier; self.modelVersion = modelVersion; self.progress = progress; self.chapters = chapters
        self.errorMessage = errorMessage; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public protocol ChapterIndexPersistence: Sendable {
    func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex?
    func upsertChapterIndex(_ index: ChapterIndex) async throws
    func markChapterIndexDirty(bookID: BookID) async throws
}

public extension ChapterIndexPersistence {
    func markChapterIndexDirty(bookID: BookID) async throws {}
}

public protocol ChapterSummarizing: Sendable {
    func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary
}

extension ChapterSummarizer: ChapterSummarizing {}

/// A format-neutral location for a chapter. The associated values deliberately
/// contain only value types so chapter records can cross an async boundary.
public enum ChapterLocator: Sendable, Equatable {
    case epub(href: String)
    case pdf(pageRange: PDFChapterPageRange)
}

public struct PDFChapterPageRange: Sendable, Equatable {
    public let startPage: Int
    public let endPage: Int

    public init(startPage: Int, endPage: Int) {
        self.startPage = startPage
        self.endPage = endPage
    }
}

public struct ChapterSourceRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sourcePosition: Int
    public let locator: ChapterLocator
    public let text: String

    public init(id: String, name: String, sourcePosition: Int = 0, locator: ChapterLocator, text: String) {
        self.id = id
        self.name = name
        self.sourcePosition = sourcePosition
        self.locator = locator
        self.text = text
    }
}

public struct ChapterSourceResult: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case available
        case partialFailure(diagnostics: [String])
        case unavailable(diagnostics: [String])
    }

    public let availability: Availability
    public let records: [ChapterSourceRecord]

    public init(availability: Availability, records: [ChapterSourceRecord]) {
        self.availability = availability
        self.records = records
    }

    public var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    public static let unavailable = Self(
        availability: .unavailable(diagnostics: ["No chapter structure is available"]),
        records: []
    )
}
