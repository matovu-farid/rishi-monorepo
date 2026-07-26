@testable import rishi
import Testing
import Foundation



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
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
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

    @Test("clear during unpack cancels the in-flight task and does not leave a stale sidecar")
    func clearDuringUnpack_cancelsInflightAndDoesNotLeaveStaleSidecar() async throws {
        let root = makeTempRootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(rootDirectory: root)
        let bookId = BookID()
        let epub = try makeMutableEPUBCopy()
        defer { try? FileManager.default.removeItem(at: epub) }

        // Kick off the unpack; race a `clear(for:)` against it. The
        // cancellation gates inside `performUnpack` (one between mkdir
        // and unzip, one after unzip returns) plus `clear`'s
        // `task.cancel()` + `await task.value` sequence ensure the
        // on-disk state is coherent on the way out:
        //
        //   - If clear arrives BEFORE unzip completes: the gate after
        //     unzip returns nil, the partial directory is removed,
        //     sidecar is never written.
        //   - If clear arrives AFTER unzip completes: clear awaits the
        //     unpack task, then removes both directory and sidecar.
        //
        // Either way: the invariant we assert is "sidecar-without-
        // directory cannot happen". A stale sidecar would have
        // mis-validated the next cold open as a warm hit.
        async let unpackResult: URL? = cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        async let clearDone: Void = cache.clear(for: bookId)
        let (_, _) = await (unpackResult, clearDone)

        let dir = root.appendingPathComponent(bookId.uuidString, isDirectory: true)
        let sidecar = root.appendingPathComponent("\(bookId.uuidString).mtime")
        let dirExists = FileManager.default.fileExists(atPath: dir.path)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)

        // The forbidden state: sidecar present without directory. That
        // is exactly the half-written-cache bug this fix closes.
        #expect(!(sidecarExists && !dirExists),
                "stale sidecar without directory — next cold open would mis-validate as warm")

        // Re-issuing unpackIfNeeded must produce a coherent warm tree
        // (or at minimum return a non-stale fast-path miss). This
        // guards against the more subtle failure where the cancelled
        // unpack left a partial directory tagged with a fresh sidecar.
        let recovery = await cache.unpackIfNeeded(for: bookId, sourceFileURL: epub)
        let recoveredDir = try #require(recovery)
        let contents = try FileManager.default.contentsOfDirectory(atPath: recoveredDir.path)
        #expect(contents.count > 0,
                "recovery unpack should produce a non-empty directory")
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
