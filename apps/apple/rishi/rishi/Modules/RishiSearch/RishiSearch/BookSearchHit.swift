import Foundation

/// One semantic-search hit returned by a `BookSearch` conformer.
///
/// Carries the matched passage text plus its source page and the similarity
/// score the conformer assigned. Sendable + Codable so the value can ride
/// across actor hops and through JSON wire formats (tool-call results,
/// debug dumps, snapshot tests) without conversion.
public struct BookSearchHit: Sendable, Equatable, Codable {
    /// Chunk text matched by the query. Already extracted from the source
    /// asset (PDF page text, EPUB paragraph) at index time.
    public let text: String

    /// 1-based page number this chunk came from. Used by the Realtime
    /// tool result so the assistant can cite the location.
    public let page: Int

    /// Similarity score from the index. Higher = more relevant. The
    /// absolute scale is conformer-defined (cosine, inner-product, etc.);
    /// callers should only compare scores within a single search result set.
    public let score: Double

    public init(text: String, page: Int, score: Double) {
        self.text = text
        self.page = page
        self.score = score
    }
}
