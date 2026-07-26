import Foundation
import SwiftData

/// Per-book SwiftData-backed table of `(chunk_id, page, text)` rows.
///
/// One store per book — `<rootURL>/Books/<bookId>/chunks.db`.
/// Writes happen at index-build time (background `IndexBuilder`); reads
/// happen at query time (voice session). The store stays private to this
/// package and is opened lazily per book so search/indexing keep the same
/// per-book isolation the previous SQLite-backed store had.
///
/// `chunkId` is the same `UInt64` USearch key that the index stores —
/// `USearchBookSearch.search` joins on it.
actor ChunkStore {

    enum StorageError: Error, Equatable {
        case dbOpenFailed(message: String)
    }

    private let context: ModelContext

    init(dbURL: URL) throws {
        do {
            let schema = Schema([ChunkRow.self])
            let configuration = ModelConfiguration(url: dbURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.context = ModelContext(container)
        } catch {
            throw StorageError.dbOpenFailed(message: String(describing: error))
        }
    }

    /// Append (or replace) chunk rows. Idempotent on `chunk_id`.
    /// Empty input is a no-op.
    func append(chunks: [(chunkId: UInt64, page: Int, text: String)]) async throws {
        guard !chunks.isEmpty else { return }

        for c in chunks {
            let chunkId = Self.storageChunkId(from: c.chunkId)
            let descriptor = FetchDescriptor<ChunkRow>(
                predicate: #Predicate { $0.chunkId == chunkId }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.page = c.page
                existing.text = c.text
            } else {
                context.insert(ChunkRow(chunkId: chunkId, page: c.page, text: c.text))
            }
        }

        try context.save()
    }

    /// Look up rows by chunk id. Returns a map keyed by chunk id; missing
    /// ids are silently absent (no throw).
    func lookup(chunkIds: [UInt64]) async throws -> [UInt64: (page: Int, text: String)] {
        guard !chunkIds.isEmpty else { return [:] }

        var out: [UInt64: (page: Int, text: String)] = [:]
        for chunkId in chunkIds {
            let storageId = Self.storageChunkId(from: chunkId)
            let descriptor = FetchDescriptor<ChunkRow>(
                predicate: #Predicate { $0.chunkId == storageId }
            )
            guard let row = try context.fetch(descriptor).first else { continue }
            out[chunkId] = (page: row.page, text: row.text)
        }

        return out
    }

    private static func storageChunkId(from chunkId: UInt64) -> Int64 {
        Int64(bitPattern: chunkId)
    }
}

@Model
final class ChunkRow {
    @Attribute(.unique) var chunkId: Int64
    var page: Int
    var text: String

    init(chunkId: Int64, page: Int, text: String) {
        self.chunkId = chunkId
        self.page = page
        self.text = text
    }
}
