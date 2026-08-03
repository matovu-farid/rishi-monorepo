import CryptoKit
import Foundation

/// The client-side representation of the generated sync projection.
///
/// It deliberately contains metadata envelopes only. Book bytes remain in
/// R2, and local filesystem paths are absent from `SyncChange` payloads.
public struct SyncObject: Sendable, Equatable {
    public let changes: [SyncChange]
    public let remoteHash: String?
    public let isTruncated: Bool

    public init(changes: [SyncChange], remoteHash: String? = nil, isTruncated: Bool = false) {
        self.changes = changes
        self.remoteHash = remoteHash
        self.isTruncated = isTruncated
    }

    /// Encodes the same sorted-key, timestamp-free JSON array that the Worker
    /// hashes. Timestamps remain on the wire for conflict resolution but are
    /// excluded from equality so clock/precision differences cannot produce a
    /// false convergence failure.
    public func canonicalHash() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonicalChanges.map {
            TimestampFreeChange(
                kind: $0.kind,
                id: $0.id,
                payload: Self.timestampFreePayload($0.payload),
                deleted: $0.deleted
            )
        })
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns timestamp-free entity/field paths that differ between two
    /// projections. Values are deliberately omitted from the diagnostic so
    /// logs do not contain book titles, highlight text, or notes.
    public func diff(against other: SyncObject) -> [String] {
        let left = Self.diagnosticChanges(changes)
        let right = Self.diagnosticChanges(other.changes)
        let keys = Set(left.keys).union(right.keys).sorted()
        var differences: [String] = []

        for key in keys {
            guard let leftChange = left[key] else {
                differences.append("\(key):missing-on-client")
                continue
            }
            guard let rightChange = right[key] else {
                differences.append("\(key):missing-on-remote")
                continue
            }
            if leftChange.deleted != rightChange.deleted {
                differences.append("\(key).deleted")
            }
            Self.appendJSONDiff(
                left: leftChange.payload,
                right: rightChange.payload,
                path: "\(key).payload",
                into: &differences
            )
        }
        return differences
    }

    private var canonicalChanges: [SyncChange] {
        changes.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private struct TimestampFreeChange: Encodable {
        let kind: String
        let id: UUID
        let payload: SyncOpaqueJSON
        let deleted: Bool
    }

    private struct DiagnosticChange {
        let deleted: Bool
        let payload: Any
    }

    public func matchesRemoteHash() throws -> Bool {
        guard let remoteHash else { return true }
        return try canonicalHash() == remoteHash
    }

    /// Merges a locally generated mutation projection into the fetched
    /// projection. Same-entity conflicts use LWW timestamps; a local change
    /// wins an exact timestamp tie so an edit made on this device is not
    /// dropped before it reaches `/api/sync/push`.
    public func merging(localChanges: [SyncChange]) -> SyncObject {
        var byEntity: [String: SyncChange] = [:]
        for remote in changes {
            let key = Self.key(for: remote)
            guard let existing = byEntity[key] else {
                byEntity[key] = remote
                continue
            }
            // A malformed or future Worker response must not crash the
            // verification pass if it contains a duplicate entity. Resolve
            // duplicates with the same LWW rule used for local/remote merge;
            // equal timestamps prefer the tombstone for safety.
            if remote.updatedAt > existing.updatedAt ||
                (remote.updatedAt == existing.updatedAt && remote.deleted && !existing.deleted) {
                byEntity[key] = remote
            }
        }
        for local in localChanges {
            let key = Self.key(for: local)
            if let remote = byEntity[key], remote.updatedAt > local.updatedAt {
                continue
            }
            if local.deleted || byEntity[key] == nil {
                byEntity[key] = local
                continue
            }
            let remote = byEntity[key]!
            byEntity[key] = SyncChange(
                kind: local.kind,
                id: local.id,
                payload: Self.mergePayload(remote: remote.payload, local: local.payload),
                updatedAt: local.updatedAt,
                deleted: false
            )
        }
        return SyncObject(changes: Array(byEntity.values), remoteHash: nil, isTruncated: isTruncated)
    }

    private static func key(for change: SyncChange) -> String {
        "\(change.kind):\(change.id.uuidString.lowercased())"
    }

    private static func timestampFreePayload(_ payload: SyncOpaqueJSON) -> SyncOpaqueJSON {
        guard let value = try? JSONSerialization.jsonObject(
            with: payload.data,
            options: [.fragmentsAllowed]
        ) else { return payload }
        let stripped = stripTimestampFields(value)
        let data = (try? JSONSerialization.data(
            withJSONObject: stripped,
            options: [.sortedKeys, .fragmentsAllowed]
        )) ?? payload.data
        return SyncOpaqueJSON(data: data)
    }

    private static func stripTimestampFields(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(stripTimestampFields)
        }
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                let (key, value) = entry
                let normalized = key.replacingOccurrences(of: "-", with: "_").lowercased()
                guard normalized != "created_at", normalized != "updated_at" else { return }
                result[key] = stripTimestampFields(value)
            }
        }
        return value
    }

    private static func diagnosticChanges(_ changes: [SyncChange]) -> [String: DiagnosticChange] {
        changes.reduce(into: [String: DiagnosticChange]()) { result, change in
            let payload = timestampFreePayload(change.payload)
            let value = (try? JSONSerialization.jsonObject(
                with: payload.data,
                options: [.fragmentsAllowed]
            )) ?? NSNull()
            result[key(for: change)] = DiagnosticChange(deleted: change.deleted, payload: value)
        }
    }

    private static func appendJSONDiff(
        left: Any,
        right: Any,
        path: String,
        into differences: inout [String]
    ) {
        if let leftObject = left as? [String: Any], let rightObject = right as? [String: Any] {
            for key in Set(leftObject.keys).union(rightObject.keys).sorted() {
                guard let leftValue = leftObject[key] else {
                    differences.append("\(path).\(key):missing-on-remote")
                    continue
                }
                guard let rightValue = rightObject[key] else {
                    differences.append("\(path).\(key):missing-on-client")
                    continue
                }
                appendJSONDiff(left: leftValue, right: rightValue, path: "\(path).\(key)", into: &differences)
            }
            return
        }
        if let leftArray = left as? [Any], let rightArray = right as? [Any] {
            guard leftArray.count == rightArray.count else {
                differences.append(path)
                return
            }
            for index in leftArray.indices {
                appendJSONDiff(left: leftArray[index], right: rightArray[index], path: "\(path)[\(index)]", into: &differences)
            }
            return
        }

        // `JSONSerialization.data(withJSONObject:)` raises an Objective-C
        // exception for top-level fragments such as String, NSNumber, or
        // NSNull. `try?` cannot catch that exception, so compare scalar JSON
        // values directly. Verification must report a mismatch, never bring
        // down the app while building diagnostics.
        if !jsonScalarValuesEqual(left, right) {
            differences.append(path)
        }
    }

    private static func jsonScalarValuesEqual(_ left: Any, _ right: Any) -> Bool {
        if let leftString = left as? String, let rightString = right as? String {
            return leftString == rightString
        }
        if let leftNumber = left as? NSNumber, let rightNumber = right as? NSNumber {
            let leftIsBoolean = String(cString: leftNumber.objCType) == "c"
            let rightIsBoolean = String(cString: rightNumber.objCType) == "c"
            return leftIsBoolean == rightIsBoolean && leftNumber == rightNumber
        }
        if left is NSNull, right is NSNull {
            return true
        }
        return false
    }

    private static func mergePayload(remote: SyncOpaqueJSON, local: SyncOpaqueJSON) -> SyncOpaqueJSON {
        guard
            let remoteObject = try? JSONSerialization.jsonObject(with: remote.data) as? [String: Any],
            let localObject = try? JSONSerialization.jsonObject(with: local.data) as? [String: Any]
        else { return local }
        var merged = remoteObject
        for (key, value) in localObject {
            // The Worker owns creation timestamps. Keeping the remote value
            // prevents a newly inserted local highlight/bookmark from
            // disagreeing with the server's accepted-at creation time.
            if key == "created_at", remoteObject[key] != nil { continue }
            merged[key] = value
        }
        let data = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? local.data
        return SyncOpaqueJSON(data: data)
    }
}

/// Rebuilds the local metadata projection after a remote pull. It is merged
/// over the fetched object so server-owned fields that are not represented in
/// Swift (for example `created_at`) are retained during equality checks.
public final class LocalSyncObjectBuilder: Sendable {
    private let bookStore: any BookStore
    private let positionStore: any PositionStore
    private let highlightStore: any HighlightStore
    private let bookmarkStore: any BookmarkStore
    private let metadataStore: any SyncMetadataStore
    private let localUserIdProvider: @Sendable () async -> UserID?
    private let workerUserIdProvider: @Sendable () async -> String?

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        bookmarkStore: any BookmarkStore,
        metadataStore: any SyncMetadataStore,
        localUserIdProvider: @escaping @Sendable () async -> UserID?,
        workerUserIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.metadataStore = metadataStore
        self.localUserIdProvider = localUserIdProvider
        self.workerUserIdProvider = workerUserIdProvider
    }

    public func build() async throws -> SyncObject {
        guard let userId = await localUserIdProvider() else {
            return SyncObject(changes: [])
        }
        let workerUserId = await workerUserIdProvider()
        var changes: [SyncChange] = []
        let books = try await bookStore.books(for: userId)

        for book in books {
            let position = try await positionStore.position(for: book.id)
            let r2Key = workerUserId.map { BookUploader.r2Key(for: book, userId: $0) }
            let bookTimestamp = try await timestamp(for: book.id, kind: .book, fallback: book.addedAt)
            changes.append(SyncChange(
                kind: SyncEntityKind.book.rawValue,
                id: book.id,
                payload: Self.serverCanonicalBookPayload(
                    try SyncPayloadCodec.encodeBook(book, r2Key: r2Key, position: position)
                ),
                updatedAt: bookTimestamp,
                deleted: false
            ))

            for highlight in try await highlightStore.highlights(for: book.id) {
                let timestamp = try await timestamp(for: highlight.id, kind: .highlight, fallback: highlight.createdAt)
                changes.append(SyncChange(
                    kind: SyncEntityKind.highlight.rawValue,
                    id: highlight.id,
                    payload: Self.serverCanonicalHighlightPayload(
                        try SyncPayloadCodec.encodeHighlight(highlight)
                    ),
                    updatedAt: timestamp,
                    deleted: false
                ))
            }

            for bookmark in try await bookmarkStore.bookmarks(for: book.id) {
                let timestamp = try await timestamp(for: bookmark.id, kind: .bookmark, fallback: bookmark.createdAt)
                changes.append(SyncChange(
                    kind: SyncEntityKind.bookmark.rawValue,
                    id: bookmark.id,
                    payload: try SyncPayloadCodec.encodeBookmark(bookmark),
                    updatedAt: timestamp,
                    deleted: false
                ))
            }
        }
        return SyncObject(changes: changes)
    }

    private static func serverCanonicalHighlightPayload(_ payload: SyncOpaqueJSON) -> SyncOpaqueJSON {
        guard
            var object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any],
            let start = object["locator_start"]
        else { return payload }
        object["locator_end"] = start
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? payload.data
        return SyncOpaqueJSON(data: data)
    }

    private static func serverCanonicalBookPayload(_ payload: SyncOpaqueJSON) -> SyncOpaqueJSON {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any]
        else { return payload }
        let serverKeys = [
            "id", "title", "author", "format_type", "current_cfi",
            "current_page", "last_progress_percent", "file_hash",
            "cover_r2_key", "file_size", "created_at",
        ]
        let filtered = object.filter { serverKeys.contains($0.key) }
        let data = (try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])) ?? payload.data
        return SyncOpaqueJSON(data: data)
    }

    private func timestamp(
        for id: UUID,
        kind: SyncEntityKind,
        fallback: Date
    ) async throws -> Date {
        if let dirtyAt = try await metadataStore.dirtyAt(entityId: id, kind: kind) {
            return dirtyAt
        }
        if let lastSyncedAt = try await metadataStore.lastSyncedAt(entityId: id, kind: kind) {
            return lastSyncedAt
        }
        return fallback
    }
}
