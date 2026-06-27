import Foundation
import USearch
import RishiLogging

/// Production `BookSearch` conformer backed by USearch (HNSW) + ChunkStore.
///
/// On-disk layout per book (set in `BookIndexLocator`):
///   `<rootURL>/Books/<bookId>/vectors.hnsw`   — USearch native binary (memory-mapped at search time)
///   `<rootURL>/Books/<bookId>/chunks.db`      — GRDB SQLite: `(chunk_id, page, text)`
///   `<rootURL>/Books/<bookId>/index.status.json` — sidecar consumed by `status(bookId:)`
///
/// Search flow:
///   1. Consult sidecar via `IndexStatusStore`. Anything but `.ready` →
///      throws `BookContextSearchError.indexNotReady` (cold-start sentinel).
///   2. Memory-map `vectors.hnsw` via `USearchIndex.view(_:)` (lazy, zero-copy).
///   3. Embed query → search top-k → look up chunk text by `chunk_id`.
///   4. Map cosine distance d ∈ [0, 2] → score = max(0, 1 - d/2) ∈ [0, 1].
///
/// USearch parameters (decided in Plan 25-RESEARCH Q1):
///   metric = .Cos, dimensions = 384, connectivity = 16 (USearch default M).
///
/// Concurrency: actor — serializes lazy index/chunk-store opens and the
/// per-call USearch search. Index handles are cached per bookId so repeated
/// searches against the same book avoid re-`view`-ing the file.
public actor USearchBookSearch: BookSearch {

    private let locator: BookIndexLocator
    private let embedder: any BookEmbedder
    private let k: Int

    // Per-book caches. USearch view(_:) is mmap-cheap but still wins from
    // not re-walking the open() path on every voice turn.
    private var openIndexes: [UUID: USearchIndex] = [:]
    private var openChunks: [UUID: ChunkStore] = [:]

    // USearch parameters (decided in Plan 25-RESEARCH Q1):
    //   metric = .cos, dimensions = 384, connectivity = 16, quantization = .f32
    // Inlined as instance-method local values because the USearch enums are
    // not Sendable in Swift 6 strict mode, so they can't ride on static lets.

    public init(
        rootURL: URL,
        embedder: any BookEmbedder,
        k: Int = 3
    ) {
        self.locator = BookIndexLocator(rootURL: rootURL)
        self.embedder = embedder
        self.k = k
    }

    public func status(bookId: UUID) async -> BookSearchStatus {
        IndexStatusStore(url: locator.statusURL(bookId)).read()
    }

    public func search(queryText: String, bookId: UUID) async throws -> [BookSearchHit] {
        let snapshot = IndexStatusStore(url: locator.statusURL(bookId)).read()
        guard case .ready = snapshot else {
            Log.event(
                "rag.search.coldstart",
                level: .info,
                data: [
                    "bookId": bookId.uuidString,
                    "status": Self.describe(snapshot),
                ]
            )
            throw BookContextSearchError.indexNotReady
        }

        let vectorsURL = locator.vectorsURL(bookId)
        guard FileManager.default.fileExists(atPath: vectorsURL.path) else {
            Log.event(
                "rag.search.missing_vectors",
                level: .error,
                data: ["bookId": bookId.uuidString]
            )
            throw BookContextSearchError.indexNotReady
        }

        let index = try openOrReuseIndex(bookId: bookId, vectorsURL: vectorsURL)
        let chunks = try openOrReuseChunkStore(bookId: bookId)

        let queryVec: [Float32]
        do {
            queryVec = try await embedder.embed(queryText)
        } catch {
            throw BookContextSearchError.embeddingFailed(message: String(describing: error))
        }

        // Over-fetch to account for `multi: true` collisions — a paragraph
        // subdivided into N sentence sub-vectors can appear up to N times in
        // the raw results. We dedupe by key (keeping the best/lowest distance
        // per key) and trim to k AFTER dedup.
        let overFetch = max(k * 4, 16)
        let rawKeys: [USearchIndex.Key]
        let rawDistances: [Float]
        do {
            let result = try index.search(vector: queryVec, count: overFetch)
            rawKeys = result.0
            rawDistances = result.1
        } catch {
            throw BookContextSearchError.underlying(message: String(describing: error))
        }
        guard !rawKeys.isEmpty else { return [] }

        // Dedupe: best distance per key, preserve first-seen order so the
        // best result still leads.
        var bestDistance: [USearchIndex.Key: Float] = [:]
        var orderedKeys: [USearchIndex.Key] = []
        for (key, distance) in zip(rawKeys, rawDistances) {
            if let prior = bestDistance[key] {
                if distance < prior { bestDistance[key] = distance }
            } else {
                bestDistance[key] = distance
                orderedKeys.append(key)
            }
        }
        let trimmedKeys = Array(orderedKeys.prefix(k))

        let lookup = try await chunks.lookup(chunkIds: trimmedKeys)
        var hits: [BookSearchHit] = []
        hits.reserveCapacity(trimmedKeys.count)
        for key in trimmedKeys {
            guard let row = lookup[key], let distance = bestDistance[key] else { continue }
            // USearch cosine distance d ∈ [0, 2]. Map to score ∈ [0, 1] where
            // 1.0 = identical, 0.0 = opposite. Clamp for FP safety.
            let score = max(0.0, min(1.0, 1.0 - Double(distance) / 2.0))
            hits.append(BookSearchHit(text: row.text, page: row.page, score: score))
        }
        return hits
    }

    // MARK: - Private

    private func openOrReuseIndex(bookId: UUID, vectorsURL: URL) throws -> USearchIndex {
        if let cached = openIndexes[bookId] { return cached }
        let idx: USearchIndex
        do {
            idx = try USearchIndex.make(
                metric: .cos,
                dimensions: 384,
                connectivity: 16,
                quantization: .f32,
                // multi: true mirrors IndexBuilder — paragraphs subdivided at
                // sentence boundaries for embedding share a single chunkId so
                // the join into chunks.db returns one full-paragraph row per
                // matched paragraph.
                multi: true
            )
            try idx.view(path: vectorsURL.path)  // memory-mapped, zero-copy
        } catch {
            throw BookContextSearchError.underlying(message: String(describing: error))
        }
        openIndexes[bookId] = idx
        return idx
    }

    private func openOrReuseChunkStore(bookId: UUID) throws -> ChunkStore {
        if let cached = openChunks[bookId] { return cached }
        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        openChunks[bookId] = store
        return store
    }

    private static func describe(_ status: BookSearchStatus) -> String {
        switch status {
        case .notIndexed: return "notIndexed"
        case let .indexing(d, t): return "indexing(\(d)/\(t))"
        case .ready: return "ready"
        case let .failed(reason): return "failed(\(reason))"
        case .staleIndexing:
            return "stale indexing"
        }
    }
}
