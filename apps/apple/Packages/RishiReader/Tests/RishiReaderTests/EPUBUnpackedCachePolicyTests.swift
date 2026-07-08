import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// Phase 34 Plan 34-05 — policy-level suite for ``EPUBUnpackedCache`` driven by
/// an in-memory ``EPUBUnpackedFileStore`` fake. The disk-backed lifecycle suite
/// (`EPUBUnpackedCacheTests`) still exercises the real `FileManager` + ZIP path;
/// this suite isolates the cache *policy* — freshness decision, eviction, and
/// key derivation — from filesystem timing so the decisions are asserted
/// directly against fake IO.
@Suite("EPUBUnpackedCache policy (fake store)")
struct EPUBUnpackedCachePolicyTests {

    /// In-memory ``EPUBUnpackedFileStore``: no disk, no real unzip. Models the
    /// directory + sidecar as a per-book record and records source mtimes.
    private final class FakeStore: EPUBUnpackedFileStore, @unchecked Sendable {
        struct Entry {
            var directoryExists: Bool
            var sidecarMtime: Date?
        }

        let lock = NSLock()
        let root = URL(fileURLWithPath: "/fake/EPUBUnpacked", isDirectory: true)
        var entries: [BookID: Entry] = [:]
        var sourceMtimes: [URL: Date] = [:]
        var unzipCount = 0
        /// If set, the next `unzip` throws to simulate an IO failure.
        var unzipShouldThrow = false

        struct UnzipFailure: Error {}

        func unpackedDirectoryURL(for bookId: BookID) -> URL {
            root.appendingPathComponent(bookId.uuidString, isDirectory: true)
        }

        func mtimeSidecarURL(for bookId: BookID) -> URL {
            root.appendingPathComponent("\(bookId.uuidString).mtime")
        }

        private func bookId(forDirectory url: URL) -> BookID? {
            BookID(uuidString: url.lastPathComponent)
        }

        private func bookId(forSidecar url: URL) -> BookID? {
            let name = url.lastPathComponent
            guard name.hasSuffix(".mtime") else { return nil }
            return BookID(uuidString: String(name.dropLast(".mtime".count)))
        }

        func directoryExists(at url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let id = bookId(forDirectory: url) else { return false }
            return entries[id]?.directoryExists ?? false
        }

        func readSidecarMtime(at url: URL) -> Date? {
            lock.lock(); defer { lock.unlock() }
            guard let id = bookId(forSidecar: url) else { return nil }
            return entries[id]?.sidecarMtime
        }

        func sourceMtime(at url: URL) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return sourceMtimes[url]
        }

        func writeSidecarMtime(_ mtime: Date, to url: URL) {
            lock.lock(); defer { lock.unlock() }
            guard let id = bookId(forSidecar: url) else { return }
            entries[id, default: Entry(directoryExists: false, sidecarMtime: nil)].sidecarMtime = mtime
        }

        func createDirectory(at url: URL) throws { /* no-op for the root */ }

        func removeItem(at url: URL) {
            lock.lock(); defer { lock.unlock() }
            if let id = bookId(forDirectory: url), url.pathExtension != "mtime" {
                entries[id]?.directoryExists = false
            }
            if let id = bookId(forSidecar: url) {
                entries[id]?.sidecarMtime = nil
            }
        }

        func unzip(sourceFileURL: URL, to destination: URL) async throws {
            let shouldThrow = lock.withLock {
                unzipShouldThrow
            }
            if shouldThrow { throw UnzipFailure() }
            lock.withLock {
                unzipCount += 1
                if let id = bookId(forDirectory: destination) {
                    entries[id, default: Entry(directoryExists: false, sidecarMtime: nil)].directoryExists = true
                }
            }
        }
    }

    private func makeCache(store: FakeStore) -> EPUBUnpackedCache {
        EPUBUnpackedCache(store: store)
    }

    @Test("key derivation maps bookId to directory + sidecar URLs")
    func keyDerivation() {
        let store = FakeStore()
        let bookId = BookID()
        let dir = store.unpackedDirectoryURL(for: bookId)
        let sidecar = store.mtimeSidecarURL(for: bookId)

        #expect(dir.lastPathComponent == bookId.uuidString)
        #expect(sidecar.lastPathComponent == "\(bookId.uuidString).mtime")
        // Sidecar sits next to the directory under the same root.
        #expect(dir.deletingLastPathComponent() == sidecar.deletingLastPathComponent())
    }

    @Test("freshness: matching mtime is a hit, drift is a miss")
    func freshnessDecision() async {
        let store = FakeStore()
        let cache = makeCache(store: store)
        let bookId = BookID()
        let source = URL(fileURLWithPath: "/fake/book.epub")
        let mtime = Date(timeIntervalSince1970: 1_000)
        store.sourceMtimes[source] = mtime

        // Cold: nothing populated → miss.
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: source) == nil)

        // Warm with the matching mtime → hit.
        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: source)
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: source) != nil)

        // Drift the source mtime beyond the 1ms tolerance → miss.
        store.sourceMtimes[source] = mtime.addingTimeInterval(5)
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: source) == nil)

        // Within tolerance (<1ms) → still a hit.
        store.sourceMtimes[source] = mtime.addingTimeInterval(0.0005)
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: source) != nil)
    }

    @Test("warm hit short-circuits: no second unzip")
    func warmHitDoesNotReUnzip() async {
        let store = FakeStore()
        let cache = makeCache(store: store)
        let bookId = BookID()
        let source = URL(fileURLWithPath: "/fake/book.epub")
        store.sourceMtimes[source] = Date(timeIntervalSince1970: 42)

        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: source)
        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: source)

        #expect(store.unzipCount == 1)
        #expect(await cache.didUnpackCount == 1)
    }

    @Test("eviction: clear removes directory + sidecar so next lookup is a miss")
    func evictionClearsEntry() async {
        let store = FakeStore()
        let cache = makeCache(store: store)
        let bookId = BookID()
        let source = URL(fileURLWithPath: "/fake/book.epub")
        store.sourceMtimes[source] = Date(timeIntervalSince1970: 7)

        _ = await cache.unpackIfNeeded(for: bookId, sourceFileURL: source)
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: source) != nil)

        await cache.clear(for: bookId)
        #expect(store.directoryExists(at: store.unpackedDirectoryURL(for: bookId)) == false)
        #expect(store.readSidecarMtime(at: store.mtimeSidecarURL(for: bookId)) == nil)
        #expect(cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: source) == nil)
    }

    @Test("unzip failure returns nil and writes no sidecar")
    func unzipFailureIsNilWithNoSidecar() async {
        let store = FakeStore()
        store.unzipShouldThrow = true
        let cache = makeCache(store: store)
        let bookId = BookID()
        let source = URL(fileURLWithPath: "/fake/book.epub")
        store.sourceMtimes[source] = Date(timeIntervalSince1970: 9)

        let result = await cache.unpackIfNeeded(for: bookId, sourceFileURL: source)
        #expect(result == nil)
        #expect(store.readSidecarMtime(at: store.mtimeSidecarURL(for: bookId)) == nil)
        #expect(await cache.didUnpackCount == 0)
    }

    @Test("concurrent callers coalesce to a single unzip")
    func concurrentCoalesce() async {
        let store = FakeStore()
        let cache = makeCache(store: store)
        let bookId = BookID()
        let source = URL(fileURLWithPath: "/fake/book.epub")
        store.sourceMtimes[source] = Date(timeIntervalSince1970: 11)

        async let a = cache.unpackIfNeeded(for: bookId, sourceFileURL: source)
        async let b = cache.unpackIfNeeded(for: bookId, sourceFileURL: source)
        _ = await (a, b)

        #expect(store.unzipCount == 1)
        #expect(await cache.didUnpackCount == 1)
    }
}
