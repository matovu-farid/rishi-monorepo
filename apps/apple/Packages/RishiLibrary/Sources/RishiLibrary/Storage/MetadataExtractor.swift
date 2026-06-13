import Foundation

/// Best-effort metadata (title + author) extraction for an on-disk book file.
///
/// Implementations MUST return `BookMetadata()` (i.e. all-nil) on any failure
/// rather than throwing. Failures are silent — the import path falls back to
/// the filename-derived title and `nil` author.
public protocol MetadataExtractor: Sendable {
    /// Decode title / author metadata from the file at `fileURL`.
    /// - Returns: A `BookMetadata` value with nil fields when the source has
    ///   no embedded metadata or cannot be parsed.
    func extractMetadata(from fileURL: URL) async -> BookMetadata
}

/// Title + author pulled from a book file's embedded metadata.
///
/// Both fields are independently nilable so callers can populate only the
/// fields they found (e.g. EPUB has `<dc:title>` but no `<dc:creator>`).
public struct BookMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?

    public init(title: String? = nil, author: String? = nil) {
        self.title = Self.sanitize(title)
        self.author = Self.sanitize(author)
    }

    /// Trim whitespace + collapse empty strings to nil so callers can use
    /// `if let` and not have to second-guess "" vs missing.
    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
