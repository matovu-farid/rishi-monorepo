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
    public let requiresDataUseConsent = true
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
    public let requiresDataUseConsent = true
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
///   "operation_id": "<uuid>",
///   "payload": { ... entity-specific fields ... },
///   "updated_at": "<ISO8601>",
///   "deleted": false
/// }
/// ```
public struct SyncChange: Codable, Sendable, Equatable {
    public let kind: String         // "book" | "position" | "highlight" | "conversation" | "message"
    public let id: UUID
    /// Stable across transport retries for one local mutation. Optional for
    /// compatibility with older callers and Workers.
    public let operationId: String?
    public let payload: SyncOpaqueJSON
    public let updatedAt: Date
    public let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case kind, id, payload, deleted
        case operationId = "operation_id"
        case updatedAt = "updated_at"
    }

    public init(kind: String, id: UUID, operationId: String? = nil, payload: SyncOpaqueJSON, updatedAt: Date, deleted: Bool) {
        self.kind = kind
        self.id = id
        self.operationId = operationId
        self.payload = payload
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    public init(kind: String, id: UUID, operationId: UUID, payload: SyncOpaqueJSON, updatedAt: Date, deleted: Bool) {
        self.init(
            kind: kind,
            id: id,
            operationId: operationId.uuidString,
            payload: payload,
            updatedAt: updatedAt,
            deleted: deleted
        )
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
        // JSONSerialization bridges every JSON number to NSNumber, and on
        // Apple `NSNumber as? Bool` succeeds for numeric values too. Inspect
        // the Objective-C type tag first so `1` cannot become `true` in the
        // canonical sync hash.
        case let number as NSNumber:
            switch String(cString: number.objCType) {
            case "c": try c.encode(number.boolValue)
            case "d", "f": try c.encode(number.doubleValue)
            default: try c.encode(number.int64Value)
            }
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

/// Scope of the opaque cursor returned by the sync changes endpoint.
public enum SyncCursorScope: String, Codable, Sendable, Equatable {
    case incremental
    /// Wire value is `full`; Apple calls this plane recovery because it is
    /// used for resumable full reconciliation.
    case recovery = "full"
    /// Durable server event sequence. This plane is additive to the
    /// projection cursor and carries unknown deletes plus operation IDs.
    case events
}

/// `GET /api/sync/changes?since=<ISO8601>` — pull all server-side changes
/// since the cursor. First launch (SYNC-02) passes `since=nil` for a full pull.
public struct SyncChangesEndpoint: WorkerEndpoint {
    public typealias Response = SyncChangesResponse

    public let method: HTTPMethod = .GET
    public let path: String
    public let requiresDataUseConsent = true
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

    /// `GET /api/sync/changes?cursor=<opaque>` — pull one cursor page.
    /// Worker cursors are URL-safe base64 values. Keep them opaque and place
    /// them directly in the query string so the WorkerClient does not encode
    /// an already-encoded `%` a second time.
    public init(cursor: String?) {
        self.init(scope: .incremental, cursor: cursor)
    }

    /// Starts either the incremental or full/recovery cursor plane. The
    /// Worker encodes the scope in the opaque cursor after the first page;
    /// the explicit query is needed only when a plane has no saved cursor yet.
    public init(scope: SyncCursorScope, cursor: String?) {
        self.since = nil
        if scope == .events {
            if let cursor {
                self.path = "/api/sync/events?after=\(cursor)"
            } else {
                self.path = "/api/sync/events"
            }
        } else if let cursor {
            self.path = "/api/sync/changes?cursor=\(cursor)"
        } else if scope == .recovery {
            self.path = "/api/sync/changes?scope=full"
        } else {
            self.path = "/api/sync/changes"
        }
    }
}

public struct SyncChangesResponse: Decodable, Sendable, Equatable {
    public let changes: [SyncChange]
    /// SHA-256 of the canonical generated projection. Optional for rolling
    /// worker deployments that still return the legacy envelope.
    public let snapshotHash: String?
    /// SHA-256 of the canonical projection with synchronization timestamps
    /// removed. New clients use this for convergence verification.
    public let snapshotHashWithoutTimestamps: String?
    public let isTruncated: Bool
    public let nextCursor: String?
    public let hasMore: Bool
    public let cursorScope: SyncCursorScope?
    public let projectionComplete: Bool
    public let snapshotHashVersion: String?

    enum CodingKeys: String, CodingKey {
        case changes
        case snapshotHash = "snapshot_hash"
        case snapshotHashWithoutTimestamps = "snapshot_hash_without_timestamps"
        case isTruncated = "is_truncated"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case cursorScope = "cursor_scope"
        case projectionComplete = "projection_complete"
        case snapshotHashVersion = "snapshot_hash_version"
    }

    public init(
        changes: [SyncChange],
        snapshotHash: String? = nil,
        snapshotHashWithoutTimestamps: String? = nil,
        isTruncated: Bool = false,
        nextCursor: String? = nil,
        hasMore: Bool = false,
        cursorScope: SyncCursorScope? = nil,
        projectionComplete: Bool = true,
        snapshotHashVersion: String? = nil
    ) {
        self.changes = changes
        self.snapshotHash = snapshotHash
        self.snapshotHashWithoutTimestamps = snapshotHashWithoutTimestamps
        self.isTruncated = isTruncated
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.cursorScope = cursorScope
        self.projectionComplete = projectionComplete
        self.snapshotHashVersion = snapshotHashVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.changes = try container.decode([SyncChange].self, forKey: .changes)
        self.snapshotHash = try container.decodeIfPresent(String.self, forKey: .snapshotHash)
        self.snapshotHashWithoutTimestamps = try container.decodeIfPresent(String.self, forKey: .snapshotHashWithoutTimestamps)
        self.isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        self.hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        self.cursorScope = try container.decodeIfPresent(SyncCursorScope.self, forKey: .cursorScope)
        self.projectionComplete = try container.decodeIfPresent(Bool.self, forKey: .projectionComplete) ?? !self.isTruncated
        self.snapshotHashVersion = try container.decodeIfPresent(String.self, forKey: .snapshotHashVersion)
    }
}

/// A page-shaped name for the additive response used by the page fetcher.
/// The typealias keeps the legacy response surface source-compatible.
public typealias SyncChangesPage = SyncChangesResponse

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
    public let requiresDataUseConsent = true
    public let body: Body

    public init(body: Body) { self.body = body }
}

public struct SyncPushResponse: Decodable, Sendable, Equatable {
    /// Server's high-water-mark cursor after applying the push. RishiSync stores
    /// this in sync_metadata.last_synced_at for the matching entity kind.
    public let acceptedAt: Date
    /// For the single-book push, whether the Worker accepted the book under
    /// its LWW rules. This is optional so clients can still talk to older
    /// Workers that only returned `accepted_at`; a missing value is treated as
    /// legacy success.
    public let accepted: Bool?
    public let outcomes: [SyncPushOutcome]

    enum CodingKeys: String, CodingKey {
        case acceptedAt = "accepted_at"
        case accepted
        case outcomes
    }

    public init(acceptedAt: Date, accepted: Bool? = nil, outcomes: [SyncPushOutcome] = []) {
        self.acceptedAt = acceptedAt
        self.accepted = accepted
        self.outcomes = outcomes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.acceptedAt = try container.decode(Date.self, forKey: .acceptedAt)
        self.accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted)
        self.outcomes = try container.decodeIfPresent([SyncPushOutcome].self, forKey: .outcomes) ?? []
    }
}

public struct SyncPushOutcome: Codable, Sendable, Equatable {
    public let operationId: String
    public let status: String
    public let sequence: Int64?

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case status
        case sequence
    }

    public init(operationId: String, status: String, sequence: Int64? = nil) {
        self.operationId = operationId
        self.status = status
        self.sequence = sequence
    }
}
