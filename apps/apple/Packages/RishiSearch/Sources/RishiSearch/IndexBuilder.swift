import Foundation
import USearch
import RishiCore
import RishiLogging

/// Chunk → embed → persist pipeline for the per-book HNSW index.
///
/// Triggered from `BookFileStorage.importBook` via the indexing hook landed
/// in Plan 25-11. Inputs are already paragraph-extracted from the source
/// asset (PDF page text, EPUB resource text) — this builder owns:
///
///   1. Optional greedy sentence packing of oversized paragraphs via
///      `ParagraphChunker.chunk(_:maxChars:)` for embedding only (MiniLM
///      truncates at ~256 wordpieces ≈ 1000 chars — closes RESEARCH
///      OQ-5/OQ-7). The packer accumulates sentences under the cap rather
///      than embedding one sentence at a time (Plan 26-01).
///   2. Calling `BookEmbedder.embed(_:)` for each (sub)chunk.
///   3. Adding each vector under the parent paragraph's `chunk_id` so the
///      Responder's tool result returns the FULL paragraph text, not a
///      sentence fragment.
///   4. Persisting the chunks.db row exactly once per paragraph (the full
///      pre-subdivision text).
///   5. Saving the USearch index to `vectors.hnsw`.
///   6. Writing the `index.status.json` sidecar — `.indexing(d, t)` between
///      batches, `.ready` on success, `.failed(reason:)` on crash.
///
/// Idempotent — re-running for the same `bookId` wipes the prior chunks.db
/// and rewrites the index from scratch.
public actor IndexBuilder {

    private let locator: BookIndexLocator
    private let embedder: any BookEmbedder
    private let progress: @Sendable (UUID, BookSearchStatus) async -> Void

    /// Paragraphs longer than this get greedy-packed at sentence boundaries
    /// BEFORE embedding — MiniLM's 64-wordpiece input window can't fit the
    /// tail of a longer paragraph, so the embedding would silently drop it.
    /// Full paragraph text is still what's stored in chunks.db and returned
    /// to the LLM. Sub-chunks are produced via
    /// `ParagraphChunker.chunk(_:maxChars:)`, which packs sentences under
    /// the cap rather than emitting one per sentence (Plan 26-01).
    private let maxEmbedChars: Int = 1000

    /// Embedding batch granularity — mirrors the Electron analog
    /// (`apps/rishi-electron/.../embeddings.ts` batch size 32). Progress
    /// callbacks fire once per batch.
    private let batchSize: Int = 32

    public init(
        rootURL: URL,
        embedder: any BookEmbedder,
        progressUpdate: @escaping @Sendable (UUID, BookSearchStatus) async -> Void = { _, _ in }
    ) {
        self.locator = BookIndexLocator(rootURL: rootURL)
        self.embedder = embedder
        self.progress = progressUpdate
    }

    /// Build (or rebuild) the per-book index from a list of paragraph entries.
    ///
    /// - Parameter bookId: target book identifier.
    /// - Parameter paragraphs: ordered `(page, text)` paragraph rows.
    ///   Already paragraph-chunked by the caller (typically via
    ///   `RishiCore.ParagraphChunker.chunk(_:)`).
    ///
    /// - Throws: any error from the embedder, USearch, or GRDB. On throw,
    ///   the status sidecar is updated to `.failed(reason: ...)` and the
    ///   progress callback fires before the error propagates.
    public func buildIndex(
        bookId: UUID,
        paragraphs: [(page: Int, text: String)]
    ) async throws {
        try locator.ensureBookDir(bookId)
        let statusStore = IndexStatusStore(url: locator.statusURL(bookId))
        let total = paragraphs.count

        do {
            try statusStore.write(.indexing(chunksDone: 0, chunksTotal: total))
            await progress(bookId, .indexing(chunksDone: 0, chunksTotal: total))

            // Wipe prior chunks.db + vectors.hnsw for idempotent rebuilds.
            try? FileManager.default.removeItem(at: locator.chunksDBURL(bookId))
            try? FileManager.default.removeItem(at: locator.vectorsURL(bookId))

            let chunks = try ChunkStore(dbURL: locator.chunksDBURL(bookId))

            // Build the USearch index in memory; save once at the end.
            // `multi: true` permits multiple vectors per key — required when
            // a paragraph is subdivided at sentence boundaries for embedding
            // but stored as ONE chunks.db row (the full paragraph text). All
            // sub-vectors share the parent paragraph's chunkId so the join
            // collapses to a single hit per relevant paragraph.
            let index = try USearchIndex.make(
                metric: .cos,
                dimensions: 384,
                connectivity: 16,
                quantization: .f32,
                multi: true
            )
            // Reserve generously (×4) — a paragraph may yield multiple
            // sentence sub-embeddings, but we don't pay for unused slots.
            try index.reserve(UInt32(max(total * 4, 1)))

            var nextChunkId: UInt64 = 1
            var done = 0

            for batch in paragraphs.chunked(into: batchSize) {
                for para in batch {
                    let chunkId = nextChunkId
                    nextChunkId += 1

                    // Per Plan 26-02: route oversize paragraphs through
                    // `chunkForIndexing`, which adds the electron positional
                    // short-paragraph heuristic on top of greedy sentence
                    // packing. The heuristic only fires within the oversize
                    // payload (multi-sub-paragraph after `chunk(_:maxChars:)`).
                    // Per-paragraph rows whose `.count <= maxEmbedChars` are
                    // passed through verbatim — moving the header drop to the
                    // upstream import call site is a future-phase concern,
                    // documented in the doc comment on `chunkForIndexing`.
                    let embedInputs: [String]
                    if para.text.count > maxEmbedChars {
                        let packed = ParagraphChunker.chunkForIndexing(
                            para.text,
                            maxChars: maxEmbedChars
                        )
                        embedInputs = packed.isEmpty ? [para.text] : packed
                    } else {
                        embedInputs = [para.text]
                    }

                    for input in embedInputs {
                        let vec = try await embedder.embed(input)
                        try index.add(key: chunkId, vector: vec)
                    }
                    // One chunks.db row per ORIGINAL paragraph, carrying the
                    // full pre-subdivision text so the tool result returns
                    // a coherent paragraph (not a sentence fragment).
                    try await chunks.append(chunks: [
                        (chunkId: chunkId, page: para.page, text: para.text),
                    ])
                    done += 1
                }
                try statusStore.write(.indexing(chunksDone: done, chunksTotal: total))
                await progress(bookId, .indexing(chunksDone: done, chunksTotal: total))
                try Task.checkCancellation()
            }

            try index.save(path: locator.vectorsURL(bookId).path)
            try statusStore.write(.ready)
            await progress(bookId, .ready)
            Log.event(
                "rag.index.built",
                level: .info,
                data: [
                    "bookId": bookId.uuidString,
                    "chunks": String(total),
                ]
            )
        } catch {
            let reason = String(describing: error)
            try? statusStore.write(.failed(reason: reason))
            await progress(bookId, .failed(reason: reason))
            Log.event(
                "rag.index.failed",
                level: .error,
                data: [
                    "bookId": bookId.uuidString,
                    "reason": reason,
                ]
            )
            throw error
        }
    }

    /// Mark a book's index as `.failed` without running a build.
    ///
    /// The indexing hook calls this on paths that abort BEFORE `buildIndex`
    /// runs — an unsupported file extension (no extractor) or a paragraph
    /// extraction throw. Without it the status sidecar stays missing
    /// (`.notIndexed`), so `BookSearchStatus.shouldBackfillIndex` stays true
    /// and every reader-open re-schedules indexing (thrash). `.failed` is
    /// terminal: backfill skips it and the indexing chip stops polling.
    ///
    /// Uses the same `BookIndexLocator` + `IndexStatusStore` the build path
    /// uses, so the sidecar lands at the canonical `index.status.json` path.
    public func markFailed(bookId: UUID, reason: String) async {
        try? locator.ensureBookDir(bookId)
        let statusStore = IndexStatusStore(url: locator.statusURL(bookId))
        try? statusStore.write(.failed(reason: reason))
        await progress(bookId, .failed(reason: reason))
    }
}

// MARK: - Helpers

private extension Array {
    /// Splits the array into batches of `size` consecutive elements.
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// Allow the multi-vector `embed` loop to be paused via `Task.checkCancellation()`
/// even when there is no async hop between iterations. The two `try` sites in
/// the per-paragraph hot loop (`embedder.embed`, `chunks.append`) already check
/// cooperative cancellation as part of `await`, so the per-batch
/// `Task.checkCancellation()` is the additional safety net.
