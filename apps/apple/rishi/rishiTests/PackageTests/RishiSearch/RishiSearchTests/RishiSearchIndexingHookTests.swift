@testable import rishi
import Foundation
import os
import Testing





/// Phase 25 Plan 25-11 — verify the production indexing hook spawns a
/// detached Task that drives `IndexBuilder` through `PerBookTextExtractor`.
///
/// `.serialized` because each test spawns `Task.detached(priority: .background)`
/// for the actual indexing work; under Swift Testing's default parallel
/// execution + the cooperative thread pool sized for the host, several
/// concurrent background tasks compete for executor threads and the
/// 5-second `waitUntil` poll runs out before any builder completes. Running
/// the suite serially keeps each detached task on a hot executor.
@Suite("RishiSearchIndexingHook (25-11)", .serialized)
struct RishiSearchIndexingHookTests {

    // MARK: - Fixtures

    /// Stub extractor that always returns the canned paragraph rows.
    /// Optionally records each call so tests can assert routing.
    private struct StubTextExtractor: PerBookTextExtractor {
        let rows: [(page: Int, text: String)]
        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] { rows }
    }

    /// Throwing extractor used to verify the hook never crashes the import
    /// path on extraction failures.
    private struct ThrowingTextExtractor: PerBookTextExtractor {
        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] {
            throw NSError(domain: "stub", code: 1)
        }
    }

    /// Slow extractor used to verify the hook publishes an indexing status
    /// before paragraph extraction finishes.
    private struct SlowTextExtractor: PerBookTextExtractor {
        let rows: [(page: Int, text: String)]
        let delayNs: UInt64

        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] {
            try await Task.sleep(nanoseconds: delayNs)
            return rows
        }
    }

    private static func makeTempRoot(_ label: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeBook(id: UUID = UUID()) -> Book {
        Book(
            id: id,
            userId: UUID(),
            title: "Fixture",
            author: nil,
            formatType: .pdf,
            addedAt: Date(),
            openedAt: nil,
            fileURL: "Books/\(id.uuidString)/fixture.pdf",
            coverPath: nil
        )
    }

    /// Poll `predicate` up to `timeout` seconds. Used to wait on the detached
    /// indexing Task without coupling to its execution order.
    private static func waitUntil(
        timeout: TimeInterval = 5.0,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000) // 25 ms
        }
        return await predicate()
    }

    // MARK: - Happy path

    @Test("scheduleIndexing returns immediately and the detached task builds the index")
    func scheduleIndexing_buildsIndexInBackground() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let extractor = StubTextExtractor(rows: [
            (page: 1, text: "alpha"),
            (page: 2, text: "beta"),
        ])
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": extractor]
        )

        // scheduleIndexing must return within a tight bound — the heavy work
        // is detached. We measure the call itself.
        let started = Date()
        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "scheduleIndexing must return without awaiting indexing work")

        // Eventually, the detached task writes the per-book files + sidecar.
        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path)
                && FileManager.default.fileExists(atPath: locator.chunksDBURL(bookId).path)
                && IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, "Detached indexing task should produce vectors.hnsw + chunks.db + .ready sidecar")
    }

    @Test("notifies chapter-index generation after the text index is ready")
    func scheduleIndexing_notifiesChapterIndexTrigger() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let trigger = ChapterTriggerRecorder()
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [(page: 1, text: "alpha")])],
            onIndexReady: { id in await trigger.record(id) }
        )

        await hook.scheduleIndexing(
            for: Self.makeBook(id: bookId),
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        let notified = await Self.waitUntil {
            await trigger.ids().contains(bookId)
        }
        #expect(notified)
    }

    @Test("scheduleIndexing marks .indexing before extraction finishes")
    func scheduleIndexing_marksIndexingBeforeExtractionCompletes() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let extractor = SlowTextExtractor(
            rows: [(page: 1, text: "alpha")],
            delayNs: 750_000_000
        )
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": extractor]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        let locator = BookIndexLocator(rootURL: root)
        let indexingVisible = await Self.waitUntil(timeout: 1.0) { @Sendable in
            if case .indexing = IndexStatusStore(url: locator.statusURL(bookId)).read() {
                return true
            }
            return false
        }
        #expect(indexingVisible, "The hook should publish .indexing before extraction completes")
    }

    @Test("Built index is searchable via USearchBookSearch")
    func builtIndex_endToEnd_searchable() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        let extractor = StubTextExtractor(rows: [
            (page: 1, text: "the quick brown fox"),
            (page: 2, text: "jumps over the lazy dog"),
        ])
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": extractor]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        // Wait on the file-system sidecar so we never race the detached
        // IndexBuilder's SQLite writer with our reader opening chunks.db.
        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, "Status should reach .ready")

        // Once `.ready` is on disk the builder has finished writing — but the
        // ChunkStore actor inside the detached Task may still hold the
        // SwiftData-backed store open for a brief tear-down moment.
        // Poll the actual search path (which opens its own SwiftData store):
        // a successful open + non-empty result is the real readiness signal.
        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)
        var hits: [BookSearchHit] = []
        let searched = await Self.waitUntil { @Sendable in
            do {
                let result = try await search.search(
                    queryText: "the quick brown fox",
                    bookId: bookId
                )
                if !result.isEmpty {
                    return true
                }
                return false
            } catch {
                return false
            }
        }
        if searched {
            hits = (try? await search.search(
                queryText: "the quick brown fox",
                bookId: bookId
            )) ?? []
        }
        #expect(searched, "Search must eventually succeed once chunks.db is releasable")
        #expect(!hits.isEmpty, "Searching the index should return at least one hit")
    }

    // MARK: - Routing + edge cases

    @Test("Unknown extension logs no_extractor and writes no index files")
    func unknownExtension_logsAndSkips() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [(1, "ignored")])]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.unknown")
        )

        // Give any (incorrectly) spawned detached task a moment to land.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let locator = BookIndexLocator(rootURL: root)
        #expect(
            !FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path),
            "Unknown extension must NOT trigger an index build"
        )
        #expect(
            !FileManager.default.fileExists(atPath: locator.chunksDBURL(bookId).path),
            "Unknown extension must NOT touch chunks.db"
        )
    }

    @Test("Routing keys are matched case-insensitively via lowercased extension")
    func routingIsCaseInsensitive() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let extractor = StubTextExtractor(rows: [(page: 1, text: "alpha")])
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["epub": extractor]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/Book.EPUB")
        )

        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, ".EPUB upper-case extension should resolve via lowercased lookup")
    }

    @Test("Extractor throwing does not propagate; status becomes .failed")
    func extractorThrow_endsAsFailedSidecar() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": ThrowingTextExtractor()]
        )

        // Must not throw out of scheduleIndexing even though the extractor
        // (inside the detached Task) throws.
        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        // The hook catches the throw inside the detached Task and must move
        // the status sidecar out of `.notIndexed` to `.failed` — otherwise
        // `BookSearchStatus.shouldBackfillIndex` stays true and every
        // reader-open re-schedules indexing (thrash). `.failed` is terminal:
        // no backfill, and the chip stops polling.
        let locator = BookIndexLocator(rootURL: root)
        let failed = await Self.waitUntil { @Sendable in
            if case .failed = IndexStatusStore(url: locator.statusURL(bookId)).read() {
                return true
            }
            return false
        }
        #expect(failed, "Extractor throw should leave status .failed, not stuck at .notIndexed")
        #expect(
            !FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path),
            "Extractor throw must not produce a vectors.hnsw file"
        )
    }

    @Test("Unknown extension writes a .failed sidecar so status leaves .notIndexed")
    func unknownExtension_endsAsFailedSidecar() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [(1, "ignored")])]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.unknown")
        )

        // No registered extractor — the hook must still mark the sidecar
        // `.failed` so `shouldBackfillIndex` skips it and the reader does not
        // re-schedule indexing on every open.
        let locator = BookIndexLocator(rootURL: root)
        let failed = await Self.waitUntil { @Sendable in
            if case .failed = IndexStatusStore(url: locator.statusURL(bookId)).read() {
                return true
            }
            return false
        }
        #expect(failed, "Unknown extension should leave status .failed, not stuck at .notIndexed")
        #expect(
            !FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path),
            "Unknown extension must NOT trigger an index build"
        )
    }

    @Test("Empty paragraphs produce a .ready sidecar without crashing")
    func emptyParagraphs_completesReady() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [])]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, "Empty paragraphs should still produce a .ready sidecar")
    }
}

private actor ChapterTriggerRecorder {
    private var recorded: [UUID] = []
    func record(_ id: UUID) { recorded.append(id) }
    func ids() -> [UUID] { recorded }
}
