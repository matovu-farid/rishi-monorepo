import Foundation
import Testing
import GRDB
@testable import RishiSearch

/// Tests for the storage layer landed in Plan 25-05 Task 1:
/// - `BookIndexLocator` (path resolution)
/// - `ChunkStore` (GRDB-backed chunk text table)
/// - `IndexStatusStore` (cold-start status sidecar)
@Suite("ChunkStore + Storage layer")
struct ChunkStoreSuite {

    // MARK: - Helpers

    private static func makeTempRoot(_ label: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RishiSearchStorageTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - BookIndexLocator

    @Test
    func locatorReturnsExpectedPaths() {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()

        let dir = locator.bookDir(bookId)
        #expect(dir.path == root.appendingPathComponent("Books").appendingPathComponent(bookId.uuidString).path)
        #expect(locator.vectorsURL(bookId).lastPathComponent == "vectors.hnsw")
        #expect(locator.chunksDBURL(bookId).lastPathComponent == "chunks.db")
        #expect(locator.statusURL(bookId).lastPathComponent == "index.status.json")
    }

    @Test
    func locatorEnsureBookDirIsIdempotent() throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()

        try locator.ensureBookDir(bookId)
        try locator.ensureBookDir(bookId)  // second call must NOT throw

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: locator.bookDir(bookId).path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    // MARK: - ChunkStore

    @Test
    func chunkStoreAppendAndLookupRoundTrip() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)

        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        try await store.append(chunks: [
            (chunkId: 1, page: 5, text: "alpha"),
            (chunkId: 2, page: 7, text: "beta"),
        ])

        let result = try await store.lookup(chunkIds: [2, 1])
        #expect(result.count == 2)
        #expect(result[1]?.page == 5)
        #expect(result[1]?.text == "alpha")
        #expect(result[2]?.page == 7)
        #expect(result[2]?.text == "beta")
    }

    @Test
    func chunkStoreEmptyAppendIsNoOp() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)

        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        try await store.append(chunks: [])

        let result = try await store.lookup(chunkIds: [1])
        #expect(result.isEmpty)
    }

    @Test
    func chunkStoreLookupOfUnknownIdReturnsEmpty() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)

        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        try await store.append(chunks: [(chunkId: 42, page: 1, text: "only-row")])

        let result = try await store.lookup(chunkIds: [999])
        #expect(result.isEmpty)
    }

    @Test
    func chunkStoreLookupEmptyIdListReturnsEmpty() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)

        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        try await store.append(chunks: [(chunkId: 1, page: 1, text: "a")])
        let result = try await store.lookup(chunkIds: [])
        #expect(result.isEmpty)
    }

    @Test
    func chunkStoreReplaceOnConflict() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)

        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        try await store.append(chunks: [(chunkId: 1, page: 5, text: "old")])
        try await store.append(chunks: [(chunkId: 1, page: 6, text: "new")])
        let result = try await store.lookup(chunkIds: [1])
        #expect(result[1]?.page == 6)
        #expect(result[1]?.text == "new")
    }

    @Test
    func chunkStorePageIndexExists() async throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        try locator.ensureBookDir(bookId)

        // Open the store (triggers migrations), then re-open the raw GRDB
        // pool to inspect index_list. ChunkStore doesn't expose its pool,
        // which is the point — we verify the table state via a second
        // independent connection.
        _ = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        let pool = try DatabasePool(path: locator.chunksDBURL(bookId).path)
        let indexNames = try await pool.read { db -> [String] in
            try Row.fetchAll(db, sql: "PRAGMA index_list('chunks')").compactMap { $0["name"] as String? }
        }
        #expect(indexNames.contains("idx_chunks_page"))
    }

    // MARK: - IndexStatusStore

    @Test
    func statusStoreReadMissingReturnsNotIndexed() {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let store = IndexStatusStore(url: locator.statusURL(UUID()))
        #expect(store.read() == .notIndexed)
    }

    @Test
    func statusStoreRoundTripIndexing() throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        let store = IndexStatusStore(url: locator.statusURL(bookId))
        try store.write(.indexing(chunksDone: 3, chunksTotal: 10))
        #expect(store.read() == .indexing(chunksDone: 3, chunksTotal: 10))
    }

    @Test
    func statusStoreRoundTripReady() throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        let store = IndexStatusStore(url: locator.statusURL(bookId))
        try store.write(.ready)
        #expect(store.read() == .ready)
    }

    @Test
    func statusStoreRoundTripFailed() throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        let store = IndexStatusStore(url: locator.statusURL(bookId))
        try store.write(.failed(reason: "model load"))
        #expect(store.read() == .failed(reason: "model load"))
    }

    @Test
    func statusStoreOverwriteReplacesPriorState() throws {
        let root = Self.makeTempRoot()
        let locator = BookIndexLocator(rootURL: root)
        let bookId = UUID()
        let store = IndexStatusStore(url: locator.statusURL(bookId))
        try store.write(.indexing(chunksDone: 1, chunksTotal: 5))
        try store.write(.ready)
        #expect(store.read() == .ready)
    }
}
