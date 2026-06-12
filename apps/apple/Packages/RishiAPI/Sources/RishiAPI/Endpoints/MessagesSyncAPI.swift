import Foundation

// MARK: - Wire row

/// Single message row on the chat-sync wire. snake_case CodingKeys match
/// the worker's Drizzle column names (packages/shared/src/schema.ts).
/// Timestamps are ms-since-epoch Int64.
///
/// NOTE: the local `Message` model has no `updatedAt` field — messages are
/// append-only on-device. The uploader synthesizes `updatedAt` from
/// `createdAt` at upload time so the wire shape stays uniform with
/// `ConversationRowWire` and the worker's LWW conflict-resolution rule
/// can key off a single `(id, updated_at)` pair across both tables.
public struct MessageRowWire: Codable, Sendable, Equatable {
    public let id: UUID
    public let conversationId: UUID
    public let role: String
    public let content: String
    public let createdAt: Int64
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        conversationId: UUID,
        role: String,
        content: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - POST /api/sync/messages

/// `POST /api/sync/messages` — upsert a batch of message rows. Worker reply
/// shape: `{ "applied_count": <int> }`. LWW on `(id, updated_at)` server-side;
/// authorization is verified by joining through `conversations.user_id`.
public struct MessagesSyncEndpoint: WorkerEndpointWithBody {
    public typealias Response = ResponseBody

    public struct Body: Encodable, Sendable, Equatable {
        public let messages: [MessageRowWire]
        public init(messages: [MessageRowWire]) { self.messages = messages }
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
    public let path: String = "/api/sync/messages"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - GET /api/sync/messages?since=<ms_epoch>

/// `GET /api/sync/messages?since=<ms_epoch>` — incremental pull of message
/// rows newer than the given watermark. Worker enforces cross-user isolation
/// by joining through conversation ownership. `nil` since pulls the full set.
public struct MessagesSyncSinceEndpoint: WorkerEndpoint {
    public typealias Response = ResponseBody

    public struct ResponseBody: Decodable, Sendable, Equatable {
        public let rows: [MessageRowWire]
        public init(rows: [MessageRowWire]) { self.rows = rows }
    }

    public let method: HTTPMethod = .GET
    public let path: String
    public let since: Int64?

    public init(since: Int64?) {
        self.since = since
        if let since {
            self.path = "/api/sync/messages?since=\(since)"
        } else {
            self.path = "/api/sync/messages"
        }
    }
}
