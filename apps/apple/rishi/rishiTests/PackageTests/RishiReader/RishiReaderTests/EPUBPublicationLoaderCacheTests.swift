@testable import rishi
import Testing
import Foundation
import ReadiumShared



/// Phase 21 Plan 21-04 — `PublicationLoader` cache integration suite.
///
/// Asserts the four loader-level invariants:
///   - first open populates the warm cache (didUnpackCount == 1)
///   - second open is a cache hit (didUnpackCount stays at 1)
///   - mtime drift rebuilds (didUnpackCount goes to 2)
///   - unpack failure falls back to the ZIP-asset path (open still succeeds)
@Suite("PublicationLoader + EPUBUnpackedCache", .serialized)
struct PublicationLoaderCacheTests {

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    /// Place the bundled alice.epub at a path that mirrors the
    /// BookFileStorage layout `<root>/<bookId>/<filename>.epub` so the
    /// loader's `bookId(forFileURL:)` can derive a BookID from the parent
    /// directory and engage the warm-cache path. Bundle URLs themselves
    /// can't be used because their parent ("Bundled") is not a UUID.
    private func makeBookLayoutEPUB(bookId: BookID) throws -> URL {
        let source = try aliceURL()
        let bookDir = URL.temporaryDirectory
            .appendingPathComponent("plan-21-04-loader-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let dest = bookDir.appendingPathComponent("alice.epub")
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private func makeBookLayoutPDF(bookId: BookID) throws -> URL {
        let bookDir = URL.temporaryDirectory
            .appendingPathComponent("plan-21-04-loader-(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let dest = bookDir.appendingPathComponent("fixture.pdf")
        try RishiReader_FixtureBuilders.writeTinyPDF(to: dest)
        return dest
    }

    private func makeCacheRoot() -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("plan-21-04-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("first open populates the unpacked cache exactly once")
    func firstOpenPopulatesUnpackCache() async throws {
        let bookId = BookID()
        let epub = try makeBookLayoutEPUB(bookId: bookId)
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent().deletingLastPathComponent()) }
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cache = EPUBUnpackedCache(configuration: .init(rootDirectory: cacheRoot))
        let loader = PublicationLoader(unpackedCache: cache)

        _ = try await loader.open(fileURL: epub)
        let count = await cache.didUnpackCount
        #expect(count == 1)
    }

    @Test("second open hits the warm cache without re-unpacking")
    func secondOpenUsesWarmCacheWithoutUnpacking() async throws {
        let bookId = BookID()
        let epub = try makeBookLayoutEPUB(bookId: bookId)
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent().deletingLastPathComponent()) }
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cache = EPUBUnpackedCache(configuration: .init(rootDirectory: cacheRoot))
        let loader = PublicationLoader(unpackedCache: cache)

        _ = try await loader.open(fileURL: epub)
        _ = try await loader.open(fileURL: epub)

        let count = await cache.didUnpackCount
        #expect(count == 1, "second open must reuse the warm cache and not re-unpack")
    }

    @Test("mtime drift between opens rebuilds the cache")
    func mtimeDriftRebuildsCache() async throws {
        let bookId = BookID()
        let epub = try makeBookLayoutEPUB(bookId: bookId)
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent().deletingLastPathComponent()) }
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cache = EPUBUnpackedCache(configuration: .init(rootDirectory: cacheRoot))
        let loader = PublicationLoader(unpackedCache: cache)

        _ = try await loader.open(fileURL: epub)
        // Drift the mtime well beyond the 1ms tolerance.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: epub.path
        )
        _ = try await loader.open(fileURL: epub)

        let count = await cache.didUnpackCount
        #expect(count == 2, "mtime drift must rebuild the warm cache on next open")
    }

    @Test("unpack failure falls back to the ZIP-asset path and still opens")
    func unpackFailureFallsBackToZipAsset() async throws {
        let bookId = BookID()
        let epub = try makeBookLayoutEPUB(bookId: bookId)
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent().deletingLastPathComponent()) }

        // Point the cache at a location we cannot write to so unpack
        // physically fails. `/dev/null/EPUBUnpacked` errors cleanly on
        // createDirectory; the loader must then fall back to the
        // ZIP-asset path and still return a valid Publication.
        let unwritable = URL(fileURLWithPath: "/dev/null/Plan-21-04-EPUBUnpacked", isDirectory: true)
        let cache = EPUBUnpackedCache(configuration: .init(rootDirectory: unwritable))
        let loader = PublicationLoader(unpackedCache: cache)

        let publication = try await loader.open(fileURL: epub)
        #expect(publication.metadata.title?.lowercased().contains("alice") == true)

        let count = await cache.didUnpackCount
        #expect(count == 0, "no successful unpack must have been recorded")
    }

    @Test("bookId is derivable from a BookFileStorage-shaped URL")
    func bookIdDerivedFromLayoutURL() throws {
        let bookId = BookID()
        let url = URL.temporaryDirectory
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
            .appendingPathComponent("alice.epub")
        #expect(PublicationLoader.bookId(forFileURL: url) == bookId)
    }

    @Test("bookId is nil for a non-layout URL (e.g. bundled fixture)")
    func bookIdNilForBundleURL() throws {
        let url = try aliceURL()
        #expect(PublicationLoader.bookId(forFileURL: url) == nil)
    }

    @Test("PDFs bypass the EPUB unpack cache and still open through Readium")
    func pdfBypassesEPUBUnpackCache() async throws {
        let bookId = BookID()
        let pdf = try makeBookLayoutPDF(bookId: bookId)
        defer {
            try? FileManager.default.removeItem(
                at: pdf.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cache = EPUBUnpackedCache(configuration: .init(rootDirectory: cacheRoot))
        let loader = PublicationLoader(unpackedCache: cache)

        let publication = try await loader.open(fileURL: pdf)

        #expect(publication.conforms(to: .pdf))
        #expect(await cache.didAttemptUnpackCount == 0)
        #expect(await cache.didUnpackCount == 0)
    }
}
