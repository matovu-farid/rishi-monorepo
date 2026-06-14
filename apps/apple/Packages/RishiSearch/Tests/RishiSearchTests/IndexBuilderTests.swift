import Foundation
import os
import Testing
@testable import RishiSearch

/// Tests for `IndexBuilder` — Plan 25-05 Task 3.
@Suite("IndexBuilder")
struct IndexBuilderSuite {

    private static func makeTempRoot(_ label: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexBuilderTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Thread-safe collector for progress callbacks.
    private final class ProgressBox: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<[(UUID, BookSearchStatus)]>(initialState: [])
        func append(_ id: UUID, _ status: BookSearchStatus) {
            state.withLock { $0.append((id, status)) }
        }
        func snapshot() -> [(UUID, BookSearchStatus)] {
            state.withLock { $0 }
        }
    }

    /// Embedder that throws on the Nth call. Used to verify the
    /// `.failed(reason:)` write-through behavior.
    private final class ThrowingEmbedder: BookEmbedder, @unchecked Sendable {
        private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        private let throwOn: Int
        private let inner = IdentityEmbedder()
        init(throwOn: Int) { self.throwOn = throwOn }
        func embed(_ text: String) async throws -> [Float32] {
            let n: Int = counter.withLock { state in
                state += 1
                return state
            }
            if n == throwOn {
                throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "boom"])
            }
            return try await inner.embed(text)
        }
        func prewarm() async {}
    }

    // MARK: - Happy path

    @Test
    func buildIndexWritesAllThreeFiles() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let progress = ProgressBox()
        let builder = IndexBuilder(
            rootURL: root,
            embedder: IdentityEmbedder(),
            progressUpdate: { id, status in progress.append(id, status) }
        )
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: "alpha"), (page: 2, text: "beta")]
        )

        let locator = BookIndexLocator(rootURL: root)
        #expect(FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path))
        #expect(FileManager.default.fileExists(atPath: locator.chunksDBURL(bookId).path))
        #expect(FileManager.default.fileExists(atPath: locator.statusURL(bookId).path))
        #expect(IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready)
    }

    @Test
    func progressCallbackFiresStartAndEnd() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let progress = ProgressBox()
        let builder = IndexBuilder(
            rootURL: root,
            embedder: IdentityEmbedder(),
            progressUpdate: { id, status in progress.append(id, status) }
        )
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: "alpha"), (page: 2, text: "beta")]
        )

        let events = progress.snapshot()
        #expect(events.contains(where: { $0.1 == .indexing(chunksDone: 0, chunksTotal: 2) }))
        #expect(events.contains(where: { $0.1 == .ready }))
        // All events must be for the right book.
        #expect(events.allSatisfy { $0.0 == bookId })
    }

    // MARK: - Oversize paragraph subdivision

    @Test
    func oversizeParagraphIsSubdividedButStoredAsFullText() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        // Build a paragraph well over 1000 chars composed of multiple
        // sentences so SentenceSplitter has something to split.
        let sentence = "This is a coherent sentence with words. "
        let oversize = String(repeating: sentence, count: 40) // 40 * 41 = 1640 chars
        #expect(oversize.count > 1000)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 7, text: oversize)]
        )

        // chunks.db must have ONE row containing the full paragraph text.
        let locator = BookIndexLocator(rootURL: root)
        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        let result = try await store.lookup(chunkIds: [1])
        #expect(result.count == 1)
        #expect(result[1]?.page == 7)
        #expect(result[1]?.text == oversize)
    }

    // MARK: - Failure path

    @Test
    func embedderFailureWritesFailedStatusAndRethrows() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let progress = ProgressBox()
        let builder = IndexBuilder(
            rootURL: root,
            embedder: ThrowingEmbedder(throwOn: 2),
            progressUpdate: { id, status in progress.append(id, status) }
        )

        await #expect(throws: Error.self) {
            try await builder.buildIndex(
                bookId: bookId,
                paragraphs: [
                    (page: 1, text: "first"),
                    (page: 2, text: "second"),
                    (page: 3, text: "third"),
                ]
            )
        }

        let locator = BookIndexLocator(rootURL: root)
        let status = IndexStatusStore(url: locator.statusURL(bookId)).read()
        if case .failed = status {
            // OK — exact reason text is implementation-detail.
        } else {
            Issue.record("Expected .failed status, got \(status)")
        }
        let events = progress.snapshot()
        #expect(events.contains(where: {
            if case .failed = $0.1 { return true } else { return false }
        }))
    }

    // MARK: - Idempotency

    @Test
    func rerunOverwritesPriorBuild() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())

        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: "alpha")]
        )
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 2, text: "beta")]
        )

        let locator = BookIndexLocator(rootURL: root)
        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        let result = try await store.lookup(chunkIds: [1])
        #expect(result[1]?.text == "beta")
        #expect(result[1]?.page == 2)
    }

    // MARK: - Round-trip via USearchBookSearch

    @Test
    func roundTripThroughUSearchBookSearch() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [
                (page: 1, text: "alpha-passage"),
                (page: 2, text: "beta-passage"),
                (page: 3, text: "gamma-passage"),
            ]
        )

        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)
        let hits = try await search.search(queryText: "alpha-passage", bookId: bookId)
        #expect(!hits.isEmpty)
        #expect(hits.first?.text == "alpha-passage")
        #expect(hits.first?.page == 1)
        // Identity embedder is deterministic — exact-match score ~ 1.0.
        #expect((hits.first?.score ?? 0) > 0.99)
    }
}
