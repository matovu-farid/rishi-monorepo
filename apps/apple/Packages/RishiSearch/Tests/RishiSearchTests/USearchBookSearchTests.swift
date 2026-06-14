import Foundation
import Testing
import USearch
import RishiLogging
@testable import RishiSearch

/// Tests for `USearchBookSearch` — the production `BookSearch` conformer
/// landed in Plan 25-05 Task 2.
///
/// Strategy: hand-build a small per-book on-disk layout (vectors.hnsw +
/// chunks.db + index.status.json) using `IdentityEmbedder` so vectors are
/// deterministic, then exercise the public `search(...)` + `status(...)`
/// surface.
@Suite("USearchBookSearch")
struct USearchBookSearchSuite {

    // MARK: - Helpers

    private static func makeTempRoot(_ label: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("USearchBookSearchTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a minimal per-book layout: writes one vectors.hnsw, populates
    /// chunks.db with N rows, and writes a `.ready` status sidecar. Returns
    /// the bookId.
    private static func seedReadyBook(
        root: URL,
        embedder: IdentityEmbedder,
        chunks: [(chunkId: UInt64, page: Int, text: String)]
    ) async throws -> UUID {
        let bookId = UUID()
        let locator = BookIndexLocator(rootURL: root)
        try locator.ensureBookDir(bookId)

        // 1) Build USearch index with one vector per chunk.
        let idx = try USearchIndex.make(
            metric: .cos,
            dimensions: 384,
            connectivity: 16,
            quantization: .f32
        )
        try idx.reserve(UInt32(max(chunks.count, 1)))
        for c in chunks {
            let vec = try await embedder.embed(c.text)
            try idx.add(key: c.chunkId, vector: vec)
        }
        try idx.save(path: locator.vectorsURL(bookId).path)

        // 2) Populate chunks.db.
        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        try await store.append(chunks: chunks)

        // 3) Mark status .ready.
        try IndexStatusStore(url: locator.statusURL(bookId)).write(.ready)

        return bookId
    }

    // MARK: - Status

    @Test
    func statusForUnknownBookReturnsNotIndexed() async {
        let root = Self.makeTempRoot()
        let search = USearchBookSearch(rootURL: root, embedder: IdentityEmbedder())
        let status = await search.status(bookId: UUID())
        #expect(status == .notIndexed)
    }

    @Test
    func statusReadsExistingSidecar() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)
        try IndexStatusStore(url: locator.statusURL(bookId))
            .write(.indexing(chunksDone: 4, chunksTotal: 10))

        let search = USearchBookSearch(rootURL: root, embedder: IdentityEmbedder())
        let status = await search.status(bookId: bookId)
        #expect(status == .indexing(chunksDone: 4, chunksTotal: 10))
    }

    // MARK: - Search happy path

    @Test
    func searchReturnsUpToKHitsOrderedBestFirst() async throws {
        let root = Self.makeTempRoot()
        let embedder = IdentityEmbedder()
        // 10 chunks; identity embedder is deterministic so the query
        // text "alpha-3" will land closest to chunk #3 (its own vector).
        var chunks: [(chunkId: UInt64, page: Int, text: String)] = []
        for i in 0..<10 {
            chunks.append((chunkId: UInt64(i + 1), page: i + 1, text: "alpha-\(i)"))
        }
        let bookId = try await Self.seedReadyBook(root: root, embedder: embedder, chunks: chunks)
        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)

        let hits = try await search.search(queryText: "alpha-3", bookId: bookId)
        #expect(hits.count == 3)
        // Score is best-first by contract.
        #expect(hits[0].score >= hits[1].score)
        #expect(hits[1].score >= hits[2].score)
        // The exact-match chunk should be the top hit (score ~ 1.0).
        #expect(hits[0].text == "alpha-3")
        #expect(hits[0].page == 4)
        #expect(hits[0].score > 0.99)
    }

    @Test
    func searchReturnsFewerThanKWhenIndexHasFewerVectors() async throws {
        let root = Self.makeTempRoot()
        let embedder = IdentityEmbedder()
        let chunks: [(chunkId: UInt64, page: Int, text: String)] = [
            (1, 5, "only-passage"),
        ]
        let bookId = try await Self.seedReadyBook(root: root, embedder: embedder, chunks: chunks)
        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)
        let hits = try await search.search(queryText: "only-passage", bookId: bookId)
        #expect(hits.count == 1)
        #expect(hits[0].text == "only-passage")
        #expect(hits[0].page == 5)
    }

    // MARK: - Cold-start sentinel

    @Test
    func searchThrowsWhenStatusIsIndexing() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)
        try IndexStatusStore(url: locator.statusURL(bookId))
            .write(.indexing(chunksDone: 0, chunksTotal: 10))
        let search = USearchBookSearch(rootURL: root, embedder: IdentityEmbedder())
        await #expect(throws: BookContextSearchError.indexNotReady) {
            _ = try await search.search(queryText: "anything", bookId: bookId)
        }
    }

    @Test
    func searchThrowsWhenStatusIsFailed() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)
        try IndexStatusStore(url: locator.statusURL(bookId))
            .write(.failed(reason: "test-crash"))
        let search = USearchBookSearch(rootURL: root, embedder: IdentityEmbedder())
        await #expect(throws: BookContextSearchError.indexNotReady) {
            _ = try await search.search(queryText: "anything", bookId: bookId)
        }
    }

    @Test
    func searchThrowsWhenStatusIsNotIndexed() async throws {
        let root = Self.makeTempRoot()
        let search = USearchBookSearch(rootURL: root, embedder: IdentityEmbedder())
        await #expect(throws: BookContextSearchError.indexNotReady) {
            _ = try await search.search(queryText: "anything", bookId: UUID())
        }
    }

    @Test
    func searchThrowsAndLogsWhenStatusReadyButVectorsMissing() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)
        // Sidecar lies — says ready, but no vectors.hnsw on disk.
        try IndexStatusStore(url: locator.statusURL(bookId)).write(.ready)

        // Install test capture before invoking; remove after.
        let captureBox = LogEventBox()
        Log._testCapture.handler = { name, _, data in
            captureBox.append(name: name, data: data)
        }
        defer { Log._testCapture.handler = nil }

        let search = USearchBookSearch(rootURL: root, embedder: IdentityEmbedder())
        await #expect(throws: BookContextSearchError.indexNotReady) {
            _ = try await search.search(queryText: "anything", bookId: bookId)
        }
        let recorded = captureBox.snapshot()
        #expect(recorded.contains(where: { $0.name == "rag.search.missing_vectors" }))
    }
}

/// Thread-safe collector for `Log._testCapture` notifications.
private final class LogEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(name: String, data: [String: String]?)] = []

    func append(name: String, data: [String: String]?) {
        lock.lock(); defer { lock.unlock() }
        events.append((name, data))
    }

    func snapshot() -> [(name: String, data: [String: String]?)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
