import Foundation
import Testing
@testable import RishiLibrary
import RishiCore
import RishiTesting

/// Phase 21 Plan 21-01 — `LibraryViewModel.refresh()` must populate
/// `coverURLs` BEFORE returning, using the nonisolated cache fast path,
/// so the library grid renders real covers on the very first paint.
/// Cache-cold books deliberately stay off `coverURLs` (gradient fallback).
@MainActor
@Suite("LibraryViewModel cover prefetch")
struct LibraryViewModelCoverPrefetchTests {

    /// No-op extractor — present only so `BookFileStorage` initialises a
    /// non-nil `CoverCache`. The cache-warm tests never invoke the slow
    /// path, so the extractor is never called.
    private struct NoopExtractor: CoverExtractor {
        func extractCover(from fileURL: URL) async -> Data? { nil }
    }

    /// Builds a `BookFileStorage` whose root is a unique tmp dir. Returns
    /// the storage, the root URL, the cache-dir URL, and the userId. The
    /// `epub` extractor slot is filled with a `NoopExtractor` so the
    /// underlying `CoverCache` is non-nil (required for the fast path).
    private static func makeFixture(label: String) -> (BookFileStorage, URL, URL, UserID, InMemoryBookStore, InMemoryPositionStore) {
        let root = URL.temporaryDirectory
            .appendingPathComponent("LVMCoverPrefetch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheDir = root
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("book-covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let bookStore = InMemoryBookStore()
        let positionStore = InMemoryPositionStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: ["epub": NoopExtractor()]
        )
        let userId = UUID()
        return (storage, root, cacheDir, userId, bookStore, positionStore)
    }

    /// Seed a cache-warm entry for `book`: write a placeholder `cover.png`
    /// at `<root>/<book.coverPath>`, then write `<bookId>.heic` and
    /// `<bookId>.mtime` under the cache dir. The mtime sidecar holds the
    /// source's modification-date interval so `cachedURLIfFresh` accepts it.
    private static func seedWarmCache(book: Book, root: URL, cacheDir: URL) throws {
        // Write the source file the cache will mtime against.
        let sourceURL = root.appendingPathComponent(book.coverPath ?? book.fileURL)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("source-bytes".utf8).write(to: sourceURL)
        // Pin a deterministic mtime so the sidecar contents are predictable.
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedDate],
            ofItemAtPath: sourceURL.path
        )
        // Write the cached HEIC payload (arbitrary bytes — fast path only
        // checks existence + sidecar match, never decodes the file).
        let heicURL = cacheDir.appendingPathComponent("\(book.id.uuidString).heic")
        try Data("fake-heic".utf8).write(to: heicURL)
        // Write the sidecar with the source mtime interval. `String(_:)` on
        // the TimeInterval is what `CoverCache` uses when writing the real
        // sidecar; mirroring that exact serialisation keeps the
        // `mtimesAreEqual` comparator happy.
        let mtimeURL = cacheDir.appendingPathComponent("\(book.id.uuidString).mtime")
        try Data(String(pinnedDate.timeIntervalSince1970).utf8).write(to: mtimeURL)
    }

    @Test("refresh populates coverURLs for cache-warm books before returning")
    func cacheWarmBooksHaveCoverURLsAfterRefresh() async throws {
        let (storage, root, cacheDir, userId, bookStore, positionStore) = Self.makeFixture(label: "warm")
        defer { try? FileManager.default.removeItem(at: root) }

        let bookA = Book(
            userId: userId,
            title: "A",
            formatType: .epub,
            fileURL: "Books/A/a.epub",
            coverPath: "Books/A/cover.png"
        )
        let bookB = Book(
            userId: userId,
            title: "B",
            formatType: .epub,
            fileURL: "Books/B/b.epub",
            coverPath: "Books/B/cover.png"
        )
        try await bookStore.upsert(bookA)
        try await bookStore.upsert(bookB)
        try Self.seedWarmCache(book: bookA, root: root, cacheDir: cacheDir)
        try Self.seedWarmCache(book: bookB, root: root, cacheDir: cacheDir)

        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId })
        )
        await vm.refresh()

        #expect(vm.books.count == 2)
        #expect(vm.coverURLs[bookA.id] != nil)
        #expect(vm.coverURLs[bookB.id] != nil)
    }

    @Test("refresh leaves coverURLs unset for cache-cold books")
    func cacheColdBookHasNoCoverURLAfterRefresh() async throws {
        let (storage, root, _, userId, bookStore, positionStore) = Self.makeFixture(label: "cold")
        defer { try? FileManager.default.removeItem(at: root) }

        let cold = Book(
            userId: userId,
            title: "Cold",
            formatType: .epub,
            fileURL: "Books/Cold/c.epub",
            coverPath: "Books/Cold/cover.png"
        )
        try await bookStore.upsert(cold)
        // Deliberately do NOT seed the cache.

        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId })
        )
        await vm.refresh()

        #expect(vm.books.count == 1)
        #expect(vm.coverURLs[cold.id] == nil)
    }

    @Test("refresh with no user empties coverURLs")
    func noUserEmptiesCoverURLs() async throws {
        let (storage, root, _, _, bookStore, positionStore) = Self.makeFixture(label: "nouser")
        defer { try? FileManager.default.removeItem(at: root) }

        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { nil },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { nil })
        )
        await vm.refresh()
        #expect(vm.coverURLs.isEmpty)
    }

    @Test("refresh ordering — coverURLs and books visible in the same MainActor turn")
    func coverURLsAndBooksAreVisibleTogether() async throws {
        let (storage, root, cacheDir, userId, bookStore, positionStore) = Self.makeFixture(label: "ordering")
        defer { try? FileManager.default.removeItem(at: root) }

        let book = Book(
            userId: userId,
            title: "Ordered",
            formatType: .epub,
            fileURL: "Books/O/o.epub",
            coverPath: "Books/O/cover.png"
        )
        try await bookStore.upsert(book)
        try Self.seedWarmCache(book: book, root: root, cacheDir: cacheDir)

        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId })
        )
        await vm.refresh()

        // After refresh returns, both must be populated; the grid binds to
        // both in the same render pass, so there is no observable state in
        // which books.count > 0 && coverURLs.isEmpty for cache-warm books.
        #expect(!vm.books.isEmpty)
        #expect(!vm.coverURLs.isEmpty)
        #expect(vm.coverURLs[book.id] != nil)
    }
}
