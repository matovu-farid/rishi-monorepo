@testable import rishi
import Foundation
import Testing


/// Phase 21 — disk cache for extracted book covers.
///
/// The cache eliminates re-extraction on cold launch and rescues books whose
/// `Book.coverPath` is NULL in the DB (i.e. imported before the extractor
/// was robust). HEIC is the on-disk format; PNG is the fallback when the
/// platform can't encode HEIC.
@Suite(.serialized)
struct CoverCacheTests {

    /// Test-only extractor that records how many times it ran and returns a
    /// deterministic PNG payload (the same 1x1 red pixel used by EPUB
    /// fixture builder).
    final class CountingExtractor: CoverExtractor, @unchecked Sendable {
        private(set) var callCount = 0
        let result: Data?

        init(result: Data?) { self.result = result }

        func extractCover(from fileURL: URL) async -> Data? {
            callCount += 1
            return result
        }
    }

    private func makeTempDir(_ label: String) -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("CoverCacheTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1x1 red PNG — same hand-encoded blob as FixtureBuilders.tinyRedPNG.
    private func tinyRedPNG() -> Data {
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x5B, 0xB6, 0x33,
            0x2A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        return Data(bytes)
    }

    @Test
    func cachesAndReturnsExtractedCover_onMiss() async throws {
        let dir = makeTempDir("miss-then-hit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("fake epub".utf8).write(to: sourceURL)

        let extractor = CountingExtractor(result: tinyRedPNG())
        let result = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)

        #expect(result != nil)
        #expect(extractor.callCount == 1)
        // The returned URL must actually exist on disk and be non-empty so a
        // subsequent AsyncImage load can decode it.
        if let url = result {
            let data = try? Data(contentsOf: url)
            #expect(data != nil)
            #expect((data?.count ?? 0) > 0)
        }
    }

    @Test
    func returnsCachedURL_withoutCallingExtractor_onHit() async throws {
        let dir = makeTempDir("hit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("fake epub".utf8).write(to: sourceURL)

        let extractor = CountingExtractor(result: tinyRedPNG())
        _ = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)
        #expect(extractor.callCount == 1)

        // Second call — cache hit. Extractor must not be invoked again.
        let second = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)
        #expect(second != nil)
        #expect(extractor.callCount == 1)
    }

    /// Phase 21 perf — nonisolated cache-hit fast path. The library renders
    /// N tiles in parallel; previously every "hit" tile had to queue behind
    /// the CoverCache actor's single executor to stat the sidecar. The
    /// `cachedURLIfFresh` helper exposes the same hit detection as a
    /// nonisolated call so all N tiles fan out truly concurrently.
    @Test
    func cachedURLIfFresh_returnsHitWithoutActorHop_afterWarmCache() async throws {
        let dir = makeTempDir("fast-path-hit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("fake epub".utf8).write(to: sourceURL)

        // Cold cache: fast path returns nil.
        #expect(cache.cachedURLIfFresh(for: bookID, sourceFileURL: sourceURL) == nil)

        // Warm the cache via the actor-isolated slow path.
        let extractor = CountingExtractor(result: tinyRedPNG())
        let warmed = await cache.cachedURL(
            for: bookID,
            sourceFileURL: sourceURL,
            extractor: extractor
        )
        #expect(warmed != nil)

        // Warm cache: fast path returns the same HEIC URL with no actor hop
        // and no extractor invocation.
        let fast = cache.cachedURLIfFresh(for: bookID, sourceFileURL: sourceURL)
        #expect(fast != nil)
        #expect(fast == warmed)
        #expect(extractor.callCount == 1)
    }

    /// Phase 21 perf — fast path must invalidate when the source file's
    /// mtime drifts past the sidecar (book file edited / re-imported). The
    /// caller then falls through to the slow path that rebuilds the cache.
    @Test
    func cachedURLIfFresh_returnsNil_whenSourceMtimeDrifts() async throws {
        let dir = makeTempDir("fast-path-stale")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("v1".utf8).write(to: sourceURL)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: sourceURL.path)

        let extractor = CountingExtractor(result: tinyRedPNG())
        _ = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)

        // Warm cache: fast path is a hit.
        #expect(cache.cachedURLIfFresh(for: bookID, sourceFileURL: sourceURL) != nil)

        // Bump the source mtime past the sidecar tolerance.
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: sourceURL.path)

        // Stale: fast path must reject so caller goes to the slow path.
        #expect(cache.cachedURLIfFresh(for: bookID, sourceFileURL: sourceURL) == nil)
    }

    @Test
    func invalidatesOnSourceFileMtimeChange() async throws {
        let dir = makeTempDir("invalidate")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("v1".utf8).write(to: sourceURL)
        // Pin an explicit old mtime so we can advance it deterministically.
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: sourceURL.path)

        let extractor = CountingExtractor(result: tinyRedPNG())
        _ = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)
        #expect(extractor.callCount == 1)

        // Touch the source — different mtime. Cache must rebuild.
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: sourceURL.path)

        _ = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)
        #expect(extractor.callCount == 2)
    }

    @Test
    func returnsNil_whenExtractorReturnsNil() async throws {
        let dir = makeTempDir("nil")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("no cover".utf8).write(to: sourceURL)

        let extractor = CountingExtractor(result: nil)
        let result = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)
        #expect(result == nil)
        #expect(extractor.callCount == 1)
    }

    @Test
    func clearRemovesCachedFile() async throws {
        let dir = makeTempDir("clear")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = CoverCache(cacheDir: cacheDir)

        let bookID = UUID()
        let sourceURL = dir.appendingPathComponent("book.epub")
        try Data("v1".utf8).write(to: sourceURL)

        let extractor = CountingExtractor(result: tinyRedPNG())
        let url = await cache.cachedURL(for: bookID, sourceFileURL: sourceURL, extractor: extractor)
        #expect(url != nil)
        if let url { #expect(FileManager.default.fileExists(atPath: url.path)) }

        await cache.clear(bookID)
        if let url { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }
}
