import Foundation
import RishiCore

/// Wire DTO for `POST /api/chat`. Cloud RAG (CHAT-03): the worker performs
/// retrieval; iOS only sends `book_id` (optional context scope) and `query`.
/// NO embeddings, NO vectors, NO retrieval params — server-owned.
public struct ChatRequest: Encodable, Sendable, Equatable {
    public let bookId: BookID?
    public let query: String

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case query
    }

    public init(bookId: BookID?, query: String) {
        self.bookId = bookId
        self.query = query
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // BookID is UUID — encode as lowercase uuidString to match worker convention.
        try c.encodeIfPresent(bookId?.uuidString.lowercased(), forKey: .bookId)
        try c.encode(query, forKey: .query)
    }
}
