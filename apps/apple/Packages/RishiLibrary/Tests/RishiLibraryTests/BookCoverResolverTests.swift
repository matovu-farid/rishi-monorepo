import Foundation
import Testing
@testable import RishiLibrary
import RishiCore
import RishiTesting

/// `BookCoverResolver` owns the fast/slow HEIC-cache decision and the
/// concurrent fan-out extracted from `LibraryViewModel` (Plan 34-11).
/// Cache-warm books resolve via the nonisolated fast path; cache-cold books
/// with no extractor payload resolve to `nil` and are omitted from the map.
@Suite("BookCoverResolver")
struct BookCoverResolverTests {

    private struct NoopExtractor: CoverExtractor {
        func extractCover(from fileURL: URL) async -> Data? { nil }
    }

    private static func makeFixture(label: String) -> (BookFileStorage, URL, URL, InMemoryBookStore) {
        let root = URL.temporaryDirectory
            .appendingPathComponent("BookCoverResolver-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheDir = root
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("book-covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let bookStore = InMemoryBookStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: ["epub": NoopExtractor()]
        )
        return (storage, root, cacheDir, bookStore)
    }

    /// Seeds a cache-warm entry: source file with a pinned mtime + a `.heic`
    /// payload + a `.mtime` sidecar matching the source mtime. Mirrors the
    /// seeding used by `LibraryViewModelCoverPrefetchTests`.
    private static func seedWarmCache(book: Book, root: URL, cacheDir: URL) throws {
        let sourceURL = root.appendingPathComponent(book.coverPath ?? book.fileURL)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("source-bytes".utf8).write(to: sourceURL)
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedDate],
            ofItemAtPath: sourceURL.path
        )
        let heicURL = cacheDir.appendingPathComponent("\(book.id.uuidString).heic")
        try Data("fake-heic".utf8).write(to: heicURL)
        let mtimeURL = cacheDir.appendingPathComponent("\(book.id.uuidString).mtime")
        try Data(String(pinnedDate.timeIntervalSince1970).utf8).write(to: mtimeURL)
    }

    private static func makeBook(title: String) -> Book {
        Book(
            userId: UUID(),
            title: title,
            formatType: .epub,
            fileURL: "Books/\(title)/\(title).epub",
            coverPath: "Books/\(title)/cover.png"
        )
    }

    @Test("coverURL returns the warm cache URL for a cache-warm book")
    func coverURL_warm() async throws {
        let (storage, root, cacheDir, _) = Self.makeFixture(label: "single-warm")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Self.makeBook(title: "A")
        try Self.seedWarmCache(book: book, root: root, cacheDir: cacheDir)

        let resolver = BookCoverResolver(storage: storage)
        let url = await resolver.coverURL(for: book)
        #expect(url != nil)
    }

    @Test("coverURL returns nil for a cache-cold book with no extractable cover")
    func coverURL_cold() async throws {
        let (storage, root, _, _) = Self.makeFixture(label: "single-cold")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Self.makeBook(title: "Cold")

        let resolver = BookCoverResolver(storage: storage)
        let url = await resolver.coverURL(for: book)
        #expect(url == nil)
    }

    @Test("coverURLs fans out and maps only books that resolve")
    func coverURLs_fanOut() async throws {
        let (storage, root, cacheDir, _) = Self.makeFixture(label: "fanout")
        defer { try? FileManager.default.removeItem(at: root) }

        let warmA = Self.makeBook(title: "WarmA")
        let warmB = Self.makeBook(title: "WarmB")
        let cold = Self.makeBook(title: "Cold")
        try Self.seedWarmCache(book: warmA, root: root, cacheDir: cacheDir)
        try Self.seedWarmCache(book: warmB, root: root, cacheDir: cacheDir)

        let resolver = BookCoverResolver(storage: storage)
        let map = await resolver.coverURLs(for: [warmA, warmB, cold])

        #expect(map[warmA.id] != nil)
        #expect(map[warmB.id] != nil)
        #expect(map[cold.id] == nil)
        #expect(map.count == 2)
    }

    @Test("coverURLs on empty input returns empty map")
    func coverURLs_empty() async throws {
        let (storage, root, _, _) = Self.makeFixture(label: "empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = BookCoverResolver(storage: storage)
        let map = await resolver.coverURLs(for: [])
        #expect(map.isEmpty)
    }
}
