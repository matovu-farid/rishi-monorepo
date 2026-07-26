@testable import rishi
import Foundation
import os
import Testing


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

    /// Embedder that records every input string handed to it, then forwards
    /// to `IdentityEmbedder` so the rest of the pipeline runs unchanged.
    /// Used to assert greedy-packing behaviour at the `embed` call boundary.
    private final class CountingEmbedder: BookEmbedder, @unchecked Sendable {
        private let inner = IdentityEmbedder()
        private let state = OSAllocatedUnfairLock<[String]>(initialState: [])
        func embed(_ text: String) async throws -> [Float32] {
            state.withLock { $0.append(text) }
            return try await inner.embed(text)
        }
        func prewarm() async {}
        func inputs() -> [String] { state.withLock { $0 } }
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

    // MARK: - Greedy paragraph packing (Plan 26-01)

    /// `maxEmbedChars` in `IndexBuilder` is 1000. A paragraph just under the
    /// cap must NOT be subdivided — exactly one embed call, with the full
    /// paragraph as input.
    @Test
    func paragraphUnderCapEmbedsOnce() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let embedder = CountingEmbedder()
        // Build a ~900-char paragraph (< 1000) from several sentences so the
        // splitter has natural boundaries available but the cap is not hit.
        let sentence = "This is a coherent sentence with words. " // 40 chars
        let text = String(repeating: sentence, count: 22) // 22 * 40 = 880
        #expect(text.count < 1000)

        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: text)]
        )

        let inputs = embedder.inputs()
        #expect(inputs.count == 1)
        #expect(inputs.first == text)
    }

    /// A paragraph at ~2x cap composed of ~10 sentences must be greedy-packed
    /// into roughly 2 chunks — NOT one embed call per sentence.
    @Test
    func paragraphTwoXCapEmitsPackedChunks() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let embedder = CountingEmbedder()
        // 10 sentences of ~200 chars each ≈ 2000 chars total — well over the
        // 1000-char embed cap.
        let body = String(repeating: "a", count: 195)
        let sentence = body + ". "
        let text = String(repeating: sentence, count: 10)
        #expect(text.count > 1900)

        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: text)]
        )

        let inputs = embedder.inputs()
        // Greedy packing should fit ~5 sentences (≈ 985 chars) per chunk,
        // yielding 2 chunks. Definitely NOT 10.
        #expect(inputs.count >= 2)
        #expect(inputs.count <= 3)
        #expect(inputs.count < 10)
        // Every embed input must respect the cap.
        #expect(inputs.allSatisfy { $0.count <= 1000 })
    }

    /// A paragraph at ~3x cap with ~30 short sentences must collapse to ~3
    /// embed calls, not 30.
    @Test
    func paragraphThreeXCapWithShortSentences() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let embedder = CountingEmbedder()
        // 30 sentences of ~100 chars each ≈ 3000 chars total.
        let body = String(repeating: "b", count: 95)
        let sentence = body + ". "
        let text = String(repeating: sentence, count: 30)
        #expect(text.count > 2800)

        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: text)]
        )

        let inputs = embedder.inputs()
        // Greedy packing should yield ~3 chunks (≈10 sentences ≈ 970 chars
        // per chunk), well below 30.
        #expect(inputs.count >= 3)
        #expect(inputs.count <= 5)
        #expect(inputs.count < 30)
        #expect(inputs.allSatisfy { $0.count <= 1000 })
    }

    /// A single sentence longer than the cap has no natural sentence boundary
    /// to pack at. `ParagraphChunker.chunk(_:maxChars:)` falls through to
    /// `hardWordSplit`, which splits on word boundaries and keeps every
    /// fragment `.count <= maxChars`. The chunks.db row still stores the
    /// original paragraph text.
    @Test
    func singleGiantSentenceFallsBackGracefully() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let embedder = CountingEmbedder()
        // 1500-char no-period sentence: 150 space-separated 9-char tokens.
        let token = "wordwordy"
        var parts: [String] = []
        for _ in 0..<150 { parts.append(token) }
        let text = parts.joined(separator: " ")
        #expect(text.count > 1000)
        #expect(!text.contains("."))

        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: text)]
        )

        let inputs = embedder.inputs()
        #expect(!inputs.isEmpty)
        // `hardWordSplit` keeps every fragment under the cap.
        #expect(inputs.allSatisfy { $0.count <= 1000 })

        // chunks.db row must still carry the FULL original paragraph text,
        // not the hard-word-split fragments.
        let locator = BookIndexLocator(rootURL: root)
        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        let result = try await store.lookup(chunkIds: [1])
        #expect(result.count == 1)
        #expect(result[1]?.text == text)
    }

    // MARK: - Plan 26-02: chunkForIndexing wire-up

    /// Pins today's behaviour after Plan 26-02 wires `IndexBuilder` to
    /// `ParagraphChunker.chunkForIndexing`. The header-drop heuristic only
    /// fires on the oversize branch (the per-paragraph row size <= cap branch
    /// passes the text through verbatim). This test exercises BOTH branches:
    ///   - A leading 9-char "Chapter 1" paragraph fits under the cap, so it
    ///     is still embedded as-is (1 vector). Limitation: the upstream
    ///     import call site is where the real header-drop happens; future
    ///     phase moves the heuristic there.
    ///   - An oversize paragraph whose embedded text begins with a sub-50-char
    ///     leading sub-paragraph (after `chunk(_:maxChars:)` greedy-packs it)
    ///     would have that leading short fragment dropped by `chunkForIndexing`,
    ///     so the embedder sees fewer inputs than the bare `chunk` path would
    ///     emit. We assert that the leading 9-char paragraph fragment does
    ///     not survive as a standalone embed input on the oversize branch.
    @Test
    func leadingTitleParagraphBranchBehaviour() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let embedder = CountingEmbedder()

        // Branch 1: short row passes through verbatim.
        let title = "Chapter 1"
        // Branch 2: oversize row whose text begins with a sub-50-char
        // paragraph followed by long sentences. The leading short
        // paragraph fragment must be dropped by `chunkForIndexing`.
        let leadingShort = "Part Two"
        let body =
            "This is a coherent sentence with words. " // 40 chars
        var oversize = leadingShort + "\n\n"
        while oversize.count < 1200 {
            oversize += body
        }
        #expect(oversize.count > 1000)

        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [
                (page: 1, text: title),
                (page: 2, text: oversize),
            ]
        )

        let inputs = embedder.inputs()
        // Branch 1: title row produced exactly one embed call equal to "Chapter 1".
        #expect(inputs.contains(title))
        // Branch 2: the leading short fragment "Part Two" must NOT appear as
        // a standalone embed input. The header-drop fires because it is the
        // first sub-paragraph of the oversize text handed to chunkForIndexing.
        #expect(!inputs.contains(leadingShort))
        // Every embed input still respects the embed cap.
        #expect(inputs.allSatisfy { $0.count <= 1000 })
    }

    /// Sanity: greedy packing changes the vector count per paragraph but the
    /// chunks.db still receives exactly one row per input paragraph.
    @Test
    func chunksDBStillOneRowPerParagraph() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        // Three paragraphs of varying sizes: under cap, 2x cap, 3x cap.
        let underCap = String(repeating: "x", count: 500)
        let twoX = String(repeating: String(repeating: "y", count: 195) + ". ", count: 10)
        let threeX = String(repeating: String(repeating: "z", count: 95) + ". ", count: 30)
        let paragraphs: [(page: Int, text: String)] = [
            (page: 1, text: underCap),
            (page: 2, text: twoX),
            (page: 3, text: threeX),
        ]

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        try await builder.buildIndex(bookId: bookId, paragraphs: paragraphs)

        let locator = BookIndexLocator(rootURL: root)
        let store = try ChunkStore(dbURL: locator.chunksDBURL(bookId))
        let result = try await store.lookup(chunkIds: [1, 2, 3])
        #expect(result.count == 3)
        #expect(result[1]?.text == underCap)
        #expect(result[2]?.text == twoX)
        #expect(result[3]?.text == threeX)
    }
}
