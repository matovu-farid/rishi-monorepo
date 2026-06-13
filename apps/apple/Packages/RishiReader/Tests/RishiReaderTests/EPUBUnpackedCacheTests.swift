import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// Phase 21 Plan 21-04 — EPUBUnpackedCache lifecycle suite.
///
/// Mirrors the CoverCache + PDFThumbnailCache patterns:
///   - cold: nothing on disk → fast-path returns nil
///   - warm: unpack happened → fast-path returns the directory URL
///   - stale: source mtime drifted → fast-path returns nil (caller rebuilds)
///   - clear: directory + sidecar removed
///   - concurrent: parallel unpack callers coalesce to a single unpack
@Suite("EPUBUnpackedCache", .serialized)
struct EPUBUnpackedCacheTests {

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    /// Copy the bundled alice.epub to a temp location so we can mutate its
    /// mtime in the drift test without touching the read-only bundle file.
    private func makeMutableEPUBCopy() throws -> URL {
        let source = try aliceURL()
        let tmp = URL.temporaryDirectory
            .appendingPathComponent("epub-cache-test-\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: source, to: tmp)
        return tmp
    }

    private func makeTempRootDirectory() -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("epub-cache-root-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCache(rootDirectory: URL) -> EPUBUnpackedCache {
        EPUBUnpackedCache(configuration: .init(rootDirectory: rootDirectory))
    }

    @Test("cold cache returns nil from the fast path")
    func coldCacheReturnsNil() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        let hit = cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: epub)
        #expect(hit == nil)
    }

    @Test("unpackIfNeeded populates the directory and writes the mtime sidecar")
    func unpackIfNeededPopulatesDirectory() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        let unpacked = await cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        let dir = try #require(unpacked)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // EPUBs have at least a mimetype + META-INF + content opf — non-empty.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.count > 0)

        // Sidecar exists.
        let sidecar = root.appendingPathComponent("\(bookId.uuidString).mtime")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        // Counter ticked exactly once.
        let count = await cache.didUnpackCount
        #expect(count == 1)
    }

    @Test("warm cache returns the directory URL without re-unpacking")
    func warmCacheReturnsDirectoryURL() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        let countAfterFirst = await cache.didUnpackCount

        // Fast path (nonisolated).
        let hit = cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: epub)
        #expect(hit != nil)

        // Slow path is a no-op when the cache is fresh.
        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        let countAfterSecond = await cache.didUnpackCount
        #expect(countAfterSecond == countAfterFirst)
    }

    @Test("mtime drift invalidates the fast-path hit")
    func mtimeDriftInvalidates() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: epub) != nil)

        // Bump the source EPUB's mtime by 10 seconds — well over the 1ms tolerance.
        let newMtime = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes(
            [.modificationDate: newMtime],
            ofItemAtPath: epub.path
        )

        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: epub) == nil)
    }

    @Test("clear removes the unpacked directory and the mtime sidecar")
    func clearRemovesDirectoryAndSidecar() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        let dir = root.appendingPathComponent(bookId.uuidString, isDirectory: true)
        let sidecar = root.appendingPathComponent("\(bookId.uuidString).mtime")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        await cache.clear(for: bookId)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("concurrent unpack callers coalesce to a single physical unpack")
    func unpackIfNeededIsIdempotent() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        async let a = cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        async let b = cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        let (urlA, urlB) = await (a, b)

        let dirA = try #require(urlA)
        let dirB = try #require(urlB)
        #expect(dirA == dirB)

        let count = await cache.didUnpackCount
        #expect(count == 1)
    }
}
