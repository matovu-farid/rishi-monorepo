import Foundation

/// `POST /v1/users/search` — sharing-invite user lookup.
///
/// Matches the electron POST shape per .planning/codebase/INTEGRATIONS.md — the
/// `q` parameter is sent in the request body, not as a query string.
public struct UsersSearchEndpoint: WorkerEndpointWithBody {
    public typealias Response = SearchResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let query: String

        public init(query: String) {
            self.query = query
        }
    }

    /// User row returned by sharing-invite search. Same shape as
    /// ``SessionUser`` but kept as a distinct type because the wire payload
    /// belongs to a different feature surface.
    public struct SearchedUser: Decodable, Sendable, Equatable, Hashable {
        public let id: String
        public let email: String
        public let displayName: String?
        public let avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case email
            case displayName = "display_name"
            case avatarURL   = "avatar_url"
        }
    }

    public struct SearchResponse: Decodable, Sendable, Equatable {
        public let users: [SearchedUser]
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/v1/users/search"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}
