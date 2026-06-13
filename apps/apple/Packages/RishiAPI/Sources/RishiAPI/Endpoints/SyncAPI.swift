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
struct SyncDownloadURLEndpoint: WorkerEndpointWithBody {
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

// MARK: - Shared sync wire types

/// Loose payload bag for a single entity change. Stays opaque at the
/// transport layer so the worker can add fields without breaking the
/// iOS decoder. Call sites (RishiSync.ChangeApplier) re-decode `payload`
/// into the concrete RishiCore model via JSONDecoder + the `kind` tag.
///
/// Wire format (sync-v1):
/// ```json
/// {
///   "kind": "position",
///   "id": "<uuid>",
///   "payload": { ... entity-specific fields ... },
///   "updated_at": "<ISO8601>",
///   "deleted": false
/// }
/// ```
public struct SyncChange: Codable, Sendable, Equatable {
    public let kind: String         // "book" | "position" | "highlight" | "conversation" | "message"
    public let id: UUID
    public let payload: SyncOpaqueJSON
    public let updatedAt: Date
    public let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case kind, id, payload, deleted
        case updatedAt = "updated_at"
    }

    public init(kind: String, id: UUID, payload: SyncOpaqueJSON, updatedAt: Date, deleted: Bool) {
        self.kind = kind
        self.id = id
        self.payload = payload
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// Opaque Codable wrapper around any JSON value the worker hands us in
/// a `payload` field. Re-encodes through Foundation's JSONSerialization so
/// we can hold on to fields the iOS schema doesn't know about yet.
public struct SyncOpaqueJSON: Codable, Sendable, Equatable {
    /// The raw bytes of the JSON object/array as canonical JSON.
    public let data: Data

    public init(data: Data) { self.data = data }

    public init(from decoder: Decoder) throws {
        // Re-encode whatever JSON the decoder sees into a stable byte buffer.
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            self.data = try JSONEncoder().encode(dict)
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.data = try JSONEncoder().encode(arr)
        } else {
            self.data = Data("null".utf8)
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Decode our bytes back into a tree, then re-encode through the host
        // encoder so JSONEncoder produces matching output.
        var c = encoder.singleValueContainer()
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let wrapped = AnyCodable(obj)
            try c.encode(wrapped)
        } else {
            try c.encodeNil()
        }
    }

    public static func == (lhs: SyncOpaqueJSON, rhs: SyncOpaqueJSON) -> Bool {
        lhs.data == rhs.data
    }
}

/// Type-erased Codable used internally by `SyncOpaqueJSON` for the
/// dictionary/array decode path.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map(\.value); return
        }
        if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value); return
        }
        self.value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map(AnyCodable.init))
        case let dict as [String: Any]: try c.encode(dict.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}

// MARK: - GET /api/sync/changes

/// `GET /api/sync/changes?since=<ISO8601>` — pull all server-side changes
/// since the cursor. First launch (SYNC-02) passes `since=nil` for a full pull.
public struct SyncChangesEndpoint: WorkerEndpoint {
    public typealias Response = SyncChangesResponse

    public let method: HTTPMethod = .GET
    public let path: String
    public let since: Date?

    public init(since: Date?) {
        self.since = since
        if let since {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = iso.string(from: since)
            // URL-encode the ISO8601 colons.
            let encoded = stamp.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stamp
            self.path = "/api/sync/changes?since=\(encoded)"
        } else {
            self.path = "/api/sync/changes"
        }
    }
}

public struct SyncChangesResponse: Decodable, Sendable, Equatable {
    public let changes: [SyncChange]

    public init(changes: [SyncChange]) { self.changes = changes }
}

// MARK: - POST /api/sync/push

/// `POST /api/sync/push` — push metadata writes (positions, highlights,
/// conversations, message tails). Book file bytes go via /sync/upload-url
/// and are not in this body.
public struct SyncPushEndpoint: WorkerEndpointWithBody {
    public typealias Response = SyncPushResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let changes: [SyncChange]
        public init(changes: [SyncChange]) { self.changes = changes }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/sync/push"
    public let body: Body

    public init(body: Body) { self.body = body }
}

public struct SyncPushResponse: Decodable, Sendable, Equatable {
    /// Server's high-water-mark cursor after applying the push. RishiSync stores
    /// this in sync_metadata.last_synced_at for the matching entity kind.
    public let acceptedAt: Date

    enum CodingKeys: String, CodingKey {
        case acceptedAt = "accepted_at"
    }

    public init(acceptedAt: Date) { self.acceptedAt = acceptedAt }
}
