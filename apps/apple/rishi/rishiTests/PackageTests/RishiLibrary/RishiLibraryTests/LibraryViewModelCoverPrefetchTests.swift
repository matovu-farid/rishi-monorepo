@testable import rishi
import Foundation
import Testing




/// Cover hydration is a bounded follow-up to base-book publication. Warm
/// cache results still resolve through the fast path; cold misses resolve nil.
@MainActor
@Suite("LibraryViewModel cover prefetch")
struct LibraryViewModelCoverPrefetchTests {

    private actor CoverPrefetchGate {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?

        func pause() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { release = $0 }
        }

        func waitUntilPaused() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            release?.resume()
            release = nil
        }
    }

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

    @Test("grid and Reading Now visibility are deduplicated until both surfaces report disappearance")
    func visiblePriorityCombinesGridAndShelf() async {
        let (storage, root, _, userId, bookStore, _) = Self.makeFixture(label: "visibility")
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(storage: storage),
            deleteBook: { _ in }
        )
        let sharedID = UUID()

        vm.setGridBookVisible(sharedID, visible: true)
        vm.setReadingNowBookVisible(sharedID, visible: true)
        #expect(vm.prioritizedCoverBookIDs == [sharedID])
        vm.setGridBookVisible(sharedID, visible: false)
        #expect(vm.prioritizedCoverBookIDs == [sharedID])
        vm.setReadingNowBookVisible(sharedID, visible: false)
        #expect(vm.prioritizedCoverBookIDs.isEmpty)
    }

    @Test("bounded hydration populates coverURLs for cache-warm books")
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
        await vm.waitForHydration()

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
        await vm.waitForHydration()

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
        await vm.waitForHydration()
        #expect(vm.coverURLs.isEmpty)
    }

    @Test("base books publish while a gated cover is unresolved")
    func booksPublishBeforeCoverHydration() async throws {
        let (storage, root, _, userId, bookStore, positionStore) = Self.makeFixture(label: "ordering")
        defer { try? FileManager.default.removeItem(at: root) }
        let coverGate = CoverPrefetchGate()
        let expectedURL = URL(fileURLWithPath: "/tmp/gated-cover.heic")

        let book = Book(
            userId: userId,
            title: "Ordered",
            formatType: .epub,
            fileURL: "Books/O/o.epub",
            coverPath: "Books/O/cover.png"
        )
        try await bookStore.upsert(book)
        let vm = LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId }),
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(resolve: { _ in
                await coverGate.pause()
                return expectedURL
            }),
            deleteBook: { _ in }
        )
        await vm.refresh()
        #expect(!vm.books.isEmpty)
        #expect(vm.coverURLs.isEmpty)
        await coverGate.waitUntilPaused()
        #expect(vm.coverURLs.isEmpty)
        await coverGate.open()
        await vm.waitForHydration()
        #expect(vm.coverURLs[book.id] == expectedURL)
    }
}
