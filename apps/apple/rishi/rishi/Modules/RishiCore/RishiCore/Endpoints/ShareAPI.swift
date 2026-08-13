import Foundation

public enum ShareKind: String, Codable, Sendable, Equatable, Hashable {
    case single
    case selection
    case library
}

public enum ShareAccess: String, Codable, Sendable, Equatable, Hashable {
    case oneTime = "one_time"
    case `public`
}

public struct SharePreviewItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let author: String?
    public let format: String
    public let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, author, format
        case coverURL = "cover_url"
    }
}

public struct SharePreview: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let senderName: String
    public let count: Int
    public let items: [SharePreviewItem]
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, count, items
        case senderName = "sender_name"
        case expiresAt = "expires_at"
    }
}

public struct ShareDownloadItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let author: String?
    public let format: String
    public let fileSize: Int
    public let fileHash: String?
    public let fileURL: String
    public let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, author, format
        case fileSize = "file_size"
        case fileHash = "file_hash"
        case fileURL = "file_url"
        case coverURL = "cover_url"
    }
}

public struct SharePackageResponse: Codable, Sendable, Equatable {
    public let id: String
    public let expiresAt: Date?
    public let link: String?
    public let preview: SharePreview?
    public let items: [ShareDownloadItem]?

    enum CodingKeys: String, CodingKey {
        case id, link, preview, items
        case expiresAt = "expires_at"
    }
}

public struct SharePreparedPackage: Codable, Sendable, Equatable {
    public let id: String
    public let generation: Int?
    public let expiresAt: Date?
    public let link: String

    enum CodingKeys: String, CodingKey {
        case id
        case generation
        case expiresAt = "expires_at"
        case link
    }

    public init(
        id: String,
        generation: Int? = nil,
        expiresAt: Date? = nil,
        link: String
    ) {
        self.id = id
        self.generation = generation
        self.expiresAt = expiresAt
        self.link = link
    }

    public var packageResponse: SharePackageResponse {
        SharePackageResponse(
            id: id,
            expiresAt: expiresAt,
            link: link,
            preview: nil,
            items: nil
        )
    }
}

public struct SharePreparedBook: Codable, Sendable, Equatable {
    public let bookID: String
    public let `public`: SharePreparedPackage
    public let oneTime: SharePreparedPackage

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case `public`
        case oneTime = "one_time"
    }
}

public struct SharePrepareSkippedBook: Codable, Sendable, Equatable {
    public let bookID: String
    public let code: String

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case code
    }

    public init(bookID: String, code: String) {
        self.bookID = bookID
        self.code = code
    }
}

public struct SharePrepareResponse: Codable, Sendable, Equatable {
    public let links: [SharePreparedBook]
    public let skipped: [SharePrepareSkippedBook]

    public init(links: [SharePreparedBook], skipped: [SharePrepareSkippedBook]) {
        self.links = links
        self.skipped = skipped
    }
}

public struct ShareCreateEndpoint: WorkerEndpointWithBody {
    public typealias Response = SharePackageResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let idempotencyKey: String
        public let kind: ShareKind
        public let bookIDs: [String]
        public let delivery: String
        public let access: ShareAccess

        enum CodingKeys: String, CodingKey {
            case idempotencyKey = "idempotency_key"
            case kind
            case bookIDs = "book_ids"
            case delivery
            case access
        }

        public init(
            idempotencyKey: String = UUID().uuidString,
            kind: ShareKind,
            bookIDs: [String],
            delivery: String = "link",
            access: ShareAccess = .oneTime
        ) {
            self.idempotencyKey = idempotencyKey
            self.kind = kind
            self.bookIDs = bookIDs
            self.delivery = delivery
            self.access = access
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/shares"
    public let requiresDataUseConsent = true
    public let body: Body

    public init(body: Body) { self.body = body }
}

public struct SharePrepareEndpoint: WorkerEndpointWithBody {
    public typealias Response = SharePrepareResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let bookIDs: [String]

        enum CodingKeys: String, CodingKey {
            case bookIDs = "book_ids"
        }

        public init(bookIDs: [String]) {
            self.bookIDs = bookIDs
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/shares/prepare"
    public let requiresDataUseConsent = true
    public let body: Body

    public init(body: Body) { self.body = body }
}

public struct SharePreviewEndpoint: WorkerEndpoint {
    public typealias Response = SharePreview

    public let method: HTTPMethod = .GET
    public let path: String
    public let requiresDataUseConsent = false

    public init(token: String) {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        self.path = "/api/shares/preview?token=\(encoded)"
    }
}

public struct ShareRedeemEndpoint: WorkerEndpointWithBody {
    public typealias Response = SharePackageResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let token: String
        public init(token: String) { self.token = token }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/shares/redeem"
    public let requiresDataUseConsent = false
    public let body: Body

    public init(token: String) { self.body = Body(token: token) }
}
