import Foundation

public enum ShareKind: String, Codable, Sendable, Equatable, Hashable {
    case single
    case selection
    case library
}

public enum ShareDelivery: String, Codable, Sendable, Equatable, Hashable {
    case link
    case username
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
    public let senderUsername: String?
    public let count: Int
    public let items: [SharePreviewItem]
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, count, items
        case senderName = "sender_name"
        case senderUsername = "sender_username"
        case expiresAt = "expires_at"
    }
}

public struct ShareDownloadItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let author: String?
    public let format: String
    public let fileSize: Int
    public let fileURL: String
    public let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, author, format
        case fileSize = "file_size"
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

public struct ShareInboxResponse: Codable, Sendable, Equatable {
    public let shares: [SharePreview]
}

public struct ShareCreateEndpoint: WorkerEndpointWithBody {
    public typealias Response = SharePackageResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let idempotencyKey: String
        public let kind: ShareKind
        public let bookIDs: [String]
        public let delivery: ShareDelivery
        public let recipientUsername: String?

        enum CodingKeys: String, CodingKey {
            case idempotencyKey = "idempotency_key"
            case kind
            case bookIDs = "book_ids"
            case delivery
            case recipientUsername = "recipient_username"
        }

        public init(
            idempotencyKey: String = UUID().uuidString,
            kind: ShareKind,
            bookIDs: [String],
            delivery: ShareDelivery,
            recipientUsername: String? = nil
        ) {
            self.idempotencyKey = idempotencyKey
            self.kind = kind
            self.bookIDs = bookIDs
            self.delivery = delivery
            self.recipientUsername = recipientUsername
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/shares"
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
    public let requiresDataUseConsent = true
    public let body: Body

    public init(token: String) { self.body = Body(token: token) }
}

public struct ShareInboxEndpoint: WorkerEndpoint {
    public typealias Response = ShareInboxResponse
    public let method: HTTPMethod = .GET
    public let path: String = "/api/shares/inbox"
    public let requiresDataUseConsent = true
    public init() {}
}

public struct ShareAcceptEndpoint: WorkerEndpointWithBody {
    public typealias Response = SharePackageResponse

    public struct Body: Encodable, Sendable, Equatable {
        public init() {}
    }

    public let method: HTTPMethod = .POST
    public let path: String
    public let requiresDataUseConsent = true
    public let body = Body()

    public init(packageID: String) {
        self.path = "/api/shares/\(packageID)/accept"
    }
}
