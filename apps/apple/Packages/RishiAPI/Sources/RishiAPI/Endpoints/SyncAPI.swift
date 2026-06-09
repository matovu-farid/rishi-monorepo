import Foundation

// MARK: - Shared response shape

/// Worker-issued presigned R2 URL with expiry. Returned by both upload-url and
/// download-url endpoints — same shape, different request bodies.
public struct PresignedURLResponse: Decodable, Sendable, Equatable {
    public let url: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case url
        case expiresAt = "expires_at"
    }
}

// MARK: - POST /api/sync/upload-url

/// `POST /api/sync/upload-url` — request a presigned R2 upload URL for a book
/// file or cover image. Phase 7 (Sync Engine) is the primary caller.
public struct SyncUploadURLEndpoint: WorkerEndpointWithBody {
    public typealias Response = PresignedURLResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let key: String
        public let contentType: String

        enum CodingKeys: String, CodingKey {
            case key
            case contentType = "content_type"
        }

        public init(key: String, contentType: String) {
            self.key = key
            self.contentType = contentType
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/sync/upload-url"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - POST /api/sync/download-url

/// `POST /api/sync/download-url` — request a presigned R2 download URL for a
/// previously-uploaded key.
public struct SyncDownloadURLEndpoint: WorkerEndpointWithBody {
    public typealias Response = PresignedURLResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let key: String

        public init(key: String) {
            self.key = key
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/sync/download-url"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}
