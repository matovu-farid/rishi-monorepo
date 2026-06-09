import Foundation

/// Best-effort cover-image extraction for an on-disk book file.
///
/// Implementations MUST return nil on any failure (corrupt file, missing
/// cover entry, unsupported format) instead of throwing. Failures are
/// logged at the call site via `Log.persistence` so the import path can
/// always insert a Book row — the grid simply falls back to the title
/// gradient when `coverPath == nil`.
public protocol CoverExtractor: Sendable {
    /// Decode the cover image from the file at `fileURL` and return PNG-encoded data.
    /// - Returns: PNG data, or nil if no cover could be extracted.
    func extractCover(from fileURL: URL) async -> Data?
}

/// Sentinel returned by ZIP / PDF helpers when the underlying source is malformed.
/// Internal — never escapes the public surface.
enum CoverExtractionError: Error {
    case sourceUnreadable
    case noCoverEntry
    case decodeFailed
}
