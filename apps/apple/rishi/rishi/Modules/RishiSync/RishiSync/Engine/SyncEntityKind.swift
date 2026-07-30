import Foundation

/// Tag for which RishiCore entity a sync_metadata row refers to.
///
/// Raw values pinned by the **sync-v2** wire format (see `RishiSync.wireFormat`).
/// Adding a new kind requires bumping the wire format AND a decoder fallback
/// that still accepts prior (sync-v1) rows. The `bookmark` case (Phase 37-08)
/// is the additive sync-v1 -> sync-v2 extension: old clients ignore the unknown
/// kind (ChangeApplier skips it), so decoding prior payloads is unaffected.
public enum SyncEntityKind: String, Codable, Sendable, CaseIterable, Hashable {
    case book         = "book"
    case position     = "position"
    case highlight    = "highlight"
    case conversation = "conversation"
    case message      = "message"
    case bookmark     = "bookmark"
    case chapterIndex = "chapter_index"
}
