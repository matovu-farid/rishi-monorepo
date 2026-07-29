import Foundation

// MARK: - Wire row

/// Single conversation row on the chat-sync wire. snake_case CodingKeys
/// match the worker's Drizzle column names (packages/shared/src/schema.ts).
/// Timestamps are ms-since-epoch Int64 (NOT ISO8601) — matches the
/// existing electron/mobile chat sync shape.
public struct ConversationRowWire: Codable, Sendable, Equatable {
    public let id: UUID
    public let userId: String
    public let bookId: String
    public let title: String
    public let archived: Bool
    public let createdAt: Int64
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case bookId = "book_id"
        case title
        case archived
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        userId: String,
        bookId: String,
        title: String,
        archived: Bool,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.userId = userId
        self.bookId = bookId
        self.title = title
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - POST /api/sync/conversations

/// `POST /api/sync/conversations` — upsert a batch of conversation rows.
/// Worker reply shape: `{ "applied_count": <int> }`. Conflict resolution
/// is last-writer-wins on `(id, updated_at)` server-side.
public struct ConversationsSyncEndpoint: WorkerEndpointWithBody {
    public typealias Response = ResponseBody

    public struct Body: Encodable, Sendable, Equatable {
        public let conversations: [ConversationRowWire]
        public init(conversations: [ConversationRowWire]) {
            self.conversations = conversations
        }
    }

    public struct ResponseBody: Decodable, Sendable, Equatable {
        public let appliedCount: Int

        enum CodingKeys: String, CodingKey {
            case appliedCount = "applied_count"
        }

        public init(appliedCount: Int) {
            self.appliedCount = appliedCount
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/sync/conversations"
    public let requiresDataUseConsent = true
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - GET /api/sync/conversations?since=<ms_epoch>

/// `GET /api/sync/conversations?since=<ms_epoch>` — incremental pull of
/// conversation rows newer than the given watermark. `nil` since pulls the
/// full set (first-launch case).
public struct ConversationsSyncSinceEndpoint: WorkerEndpoint {
    public typealias Response = ResponseBody

    public struct ResponseBody: Decodable, Sendable, Equatable {
        public let rows: [ConversationRowWire]
        public init(rows: [ConversationRowWire]) { self.rows = rows }
    }

    public let method: HTTPMethod = .GET
    public let path: String
    public let requiresDataUseConsent = true
    public let since: Int64?

    public init(since: Int64?) {
        self.since = since
        if let since {
            self.path = "/api/sync/conversations?since=\(since)"
        } else {
            self.path = "/api/sync/conversations"
        }
    }
}
