import Foundation

// MARK: - POST /v1/sessions

/// `POST /v1/sessions` — create a sharing session (host role). Phase 11+
/// sharing flow consumes this when the host clicks "Start sharing".
struct CreateSessionEndpoint: WorkerEndpointWithBody {
    public typealias Response = CreateResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let bookId: String?

        enum CodingKeys: String, CodingKey {
            case bookId = "book_id"
        }

        public init(bookId: String? = nil) {
            self.bookId = bookId
        }
    }

    public struct CreateResponse: Decodable, Sendable, Equatable {
        public let sessionId: String
        public let reconnectToken: String
        public let wsUrl: String
        public let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case sessionId      = "session_id"
            case reconnectToken = "reconnect_token"
            case wsUrl          = "ws_url"
            case expiresAt      = "expires_at"
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/v1/sessions"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - POST /v1/sessions/:id/redeem

/// `POST /v1/sessions/:id/redeem` — redeem a join token (viewer role).
///
/// The session id is interpolated into the path; the join token travels in
/// the body so it never lands in worker logs / proxies as a query param.
struct RedeemSessionEndpoint: WorkerEndpointWithBody {
    public typealias Response = RedeemResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let token: String

        public init(token: String) {
            self.token = token
        }
    }

    public struct RedeemResponse: Decodable, Sendable, Equatable {
        public let success: Bool
        public let hostUserId: String?

        enum CodingKeys: String, CodingKey {
            case success
            case hostUserId = "host_user_id"
        }
    }

    public let sessionId: String
    public let body: Body

    public init(sessionId: String, body: Body) {
        self.sessionId = sessionId
        self.body = body
    }

    public let method: HTTPMethod = .POST
    public var path: String { "/v1/sessions/\(sessionId)/redeem" }
}
