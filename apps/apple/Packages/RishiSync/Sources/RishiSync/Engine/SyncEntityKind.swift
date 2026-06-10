import Foundation

/// Tag for which RishiCore entity a sync_metadata row refers to.
///
/// Raw values pinned by the **sync-v1** wire format (see `RishiSync.wireFormat`).
/// Adding a new kind requires bumping the wire format AND a decoder fallback
/// that still accepts sync-v1 rows.
public enum SyncEntityKind: String, Codable, Sendable, CaseIterable, Hashable {
    case book         = "book"
    case position     = "position"
    case highlight    = "highlight"
    case conversation = "conversation"
    case message      = "message"
}
