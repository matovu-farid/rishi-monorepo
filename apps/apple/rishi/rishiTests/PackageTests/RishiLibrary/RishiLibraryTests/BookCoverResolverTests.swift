@testable import rishi
import Foundation
import CoreGraphics
import ImageIO
import Testing




/// `BookCoverResolver` owns the fast/slow HEIC-cache decision and the
/// concurrent fan-out extracted from `LibraryViewModel` (Plan 34-11).
/// Cache-warm books resolve via the nonisolated fast path; cache-cold books
/// with no extractor payload resolve to `nil` and are omitted from the map.
@Suite("BookCoverResolver")
struct BookCoverResolverTests {

    private actor CoverWorkGate {
        private(set) var started: [BookID] = []
        private(set) var active = 0
        private(set) var maximumActive = 0
        private var continuations: [BookID: CheckedContinuation<URL?, Never>] = [:]
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func resolve(_ book: Book) async -> URL? {
            active += 1
            maximumActive = max(maximumActive, active)
            started.append(book.id)
            let ready = startWaiters.filter { started.count >= $0.0 }
            startWaiters.removeAll { started.count >= $0.0 }
            ready.forEach { $0.1.resume() }
            return await withCheckedContinuation { continuations[book.id] = $0 }
        }

        func waitForStarts(_ count: Int) async {
            guard started.count < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        func release(_ id: BookID, url: URL? = nil) {
            active -= 1
            continuations.removeValue(forKey: id)?.resume(returning: url)
        }

        func snapshot() -> (started: [BookID], active: Int, maximumActive: Int) {
            (started, active, maximumActive)
        }
    }

    private struct NoopExtractor: CoverExtractor {
        func extractCover(from fileURL: URL) async -> Data? { nil }
    }

    private actor ExtractorSpy: CoverExtractor {
        private var calls = 0
        func extractCover(from fileURL: URL) async -> Data? { calls += 1; return nil }
        func callCount() -> Int { calls }
    }

    private actor ReadinessCallCounter {
        private var calls = 0
        func increment() { calls += 1 }
        func value() -> Int { calls }
    }

    private actor ChangingCanonicalBookStore: BookStore {
        private var reads = 0
        private var canonical: Book
        private let changed: Book
        init(canonical: Book, changed: Book) { self.canonical = canonical; self.changed = changed }
        func books(for userId: UserID) async throws -> [Book] { [canonical] }
        func book(_ id: BookID) async throws -> Book? {
            reads += 1
            return reads >= 2 ? changed : canonical
        }
        func upsert(_ book: Book) async throws { canonical = book }
        func delete(_ id: BookID) async throws { canonical = changed }
    }

    private static func makeValidPNG(width: Int = 3, height: Int = 5) throws -> Data {
        let data = NSMutableData()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let filledImage = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, filledImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private static func makeOwnedBook(owner: UserID, coverPath: String? = "cover.png") -> Book {
        let id = UUID()
        let directory = "Books/\(id.uuidString)"
        return Book(id: id, userId: owner, title: "Artwork fixture", formatType: .epub,
                    fileURL: "\(directory)/\(id.uuidString).epub",
                    coverPath: coverPath.map { "\(directory)/\($0)" })
    }

    private static func decodeSize(_ url: URL?) -> (Int, Int)? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
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

    @Test("legacy raw artwork resolves without managed readiness or cache writes")
    func legacyRawArtworkBypassesManagedReadiness() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("CoverRaw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Self.makeOwnedBook(owner: owner)
        let rawURL = root.appendingPathComponent(book.coverPath!)
        let cacheDir = root.appendingPathComponent("Caches/book-covers", isDirectory: true)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Self.makeValidPNG().write(to: rawURL)
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: rawURL.path)
        let staleCache = cacheDir.appendingPathComponent("\(book.id.uuidString).heic")
        try Self.makeValidPNG(width: 8, height: 9).write(to: staleCache)
        try Data("1".utf8).write(to: cacheDir.appendingPathComponent("\(book.id.uuidString).mtime"))
        let store = InMemoryBookStore(initial: [book])
        let extractor = ExtractorSpy()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: ["epub": extractor])
        let resolver = BookCoverResolver(storage: storage, isManagedReady: { _ in false }, isArtworkReadAllowed: { _ in true })

        let result = await resolver.coverURL(for: book)
        #expect(result == rawURL)
        #expect(Self.decodeSize(result)?.0 == 3)
        #expect(Self.decodeSize(result)?.1 == 5)
        #expect(await extractor.callCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).sorted() == ["\(book.id.uuidString).heic", "\(book.id.uuidString).mtime"])
    }

    @Test("denied managed source with no usable artwork does not extract or create cache files")
    func deniedManagedSourceDoesNotExtract() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("CoverDenied-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Self.makeOwnedBook(owner: owner, coverPath: nil)
        let store = InMemoryBookStore(initial: [book])
        let extractor = ExtractorSpy()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: ["epub": extractor])
        let resolver = BookCoverResolver(storage: storage, isManagedReady: { _ in false }, isArtworkReadAllowed: { _ in true })

        #expect(await resolver.coverURL(for: book) == nil)
        #expect(await extractor.callCount() == 0)
        let cacheDir = root.appendingPathComponent("Caches/book-covers", isDirectory: true)
        let cacheIsEmpty: Bool
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            cacheIsEmpty = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).isEmpty
        } else {
            cacheIsEmpty = true
        }
        #expect(cacheIsEmpty)
    }

    @Test("invalid image path and final canonical mismatch fail closed before managed fallback")
    func invalidOrChangedCanonicalDoesNotFallThrough() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("CoverCanonical-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let id = UUID()
        let invalidBook = Book(id: id, userId: owner, title: "Traversal", formatType: .epub,
                               fileURL: "Books/\(id.uuidString)/../outside.epub",
                               coverPath: "Books/\(id.uuidString)/cover.png")
        let traversalStore = InMemoryBookStore(initial: [invalidBook])
        let traversalExtractor = ExtractorSpy()
        let traversalStorage = BookFileStorage(rootURL: root, bookStore: traversalStore, coverExtractors: ["epub": traversalExtractor])
        let traversalReadiness = ReadinessCallCounter()
        let traversalResolver = BookCoverResolver(storage: traversalStorage, isManagedReady: { _ in await traversalReadiness.increment(); return true }, isArtworkReadAllowed: { _ in true })
        #expect(await traversalResolver.coverURL(for: invalidBook) == nil)
        #expect(await traversalReadiness.value() == 0)
        #expect(await traversalExtractor.callCount() == 0)

        let book = Self.makeOwnedBook(owner: owner)
        let rawURL = root.appendingPathComponent(book.coverPath!)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeValidPNG().write(to: rawURL)
        var changed = book
        changed.title = "Changed canonical row"
        let changingStore = ChangingCanonicalBookStore(canonical: book, changed: changed)
        let raceExtractor = ExtractorSpy()
        let raceStorage = BookFileStorage(rootURL: root, bookStore: changingStore, coverExtractors: ["epub": raceExtractor])
        let raceReadiness = ReadinessCallCounter()
        let raceResolver = BookCoverResolver(storage: raceStorage, isManagedReady: { _ in await raceReadiness.increment(); return true }, isArtworkReadAllowed: { _ in true })
        #expect(await raceResolver.coverURL(for: book) == nil)
        #expect(await raceReadiness.value() == 0)
        #expect(await raceExtractor.callCount() == 0)
    }

    @Test("book, saved-cover, cache and sidecar symlink escapes are rejected")
    func artworkSymlinkEscapesFailClosed() async throws {
        let owner = UUID()
        let outside = URL.temporaryDirectory.appendingPathComponent("CoverSymlinkOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("sentinel.png")
        let sentinelData = try Self.makeValidPNG()
        try sentinelData.write(to: sentinel)

        let root = URL.temporaryDirectory.appendingPathComponent("CoverSymlinkRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Books", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Caches/book-covers", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let foreignID = UUID()
        let foreignDirectory = root.appendingPathComponent("Books/\(foreignID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
        let directoryBook = Self.makeOwnedBook(owner: owner, coverPath: nil)
        let directoryURL = root.appendingPathComponent("Books/\(directoryBook.id.uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryURL, withDestinationURL: foreignDirectory)
        let directoryStore = InMemoryBookStore(initial: [directoryBook])
        let directorySpy = ExtractorSpy()
        let directoryStorage = BookFileStorage(rootURL: root, bookStore: directoryStore, coverExtractors: ["epub": directorySpy])
        let directoryResolver = BookCoverResolver(storage: directoryStorage, isManagedReady: { _ in true }, isArtworkReadAllowed: { _ in true })
        #expect(await directoryResolver.coverURL(for: directoryBook) == nil)
        #expect(await directorySpy.callCount() == 0)

        let coverBook = Self.makeOwnedBook(owner: owner)
        let coverURL = root.appendingPathComponent(coverBook.coverPath!)
        try FileManager.default.createDirectory(at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: coverURL, withDestinationURL: sentinel)
        let coverSpy = ExtractorSpy()
        let coverResolver = BookCoverResolver(
            storage: BookFileStorage(rootURL: root, bookStore: InMemoryBookStore(initial: [coverBook]), coverExtractors: ["epub": coverSpy]),
            isManagedReady: { _ in true }, isArtworkReadAllowed: { _ in true }
        )
        #expect(await coverResolver.coverURL(for: coverBook) == nil)
        #expect(await coverSpy.callCount() == 0)

        for escapeSidecar in [false, true] {
            let cacheBook = Self.makeOwnedBook(owner: owner, coverPath: nil)
            let cacheURL = root.appendingPathComponent("Caches/book-covers/\(cacheBook.id.uuidString).heic")
            let sidecarURL = root.appendingPathComponent("Caches/book-covers/\(cacheBook.id.uuidString).mtime")
            try FileManager.default.createSymbolicLink(at: escapeSidecar ? sidecarURL : cacheURL, withDestinationURL: sentinel)
            if escapeSidecar {
                try Self.makeValidPNG().write(to: cacheURL)
            } else {
                try Data("1700000000".utf8).write(to: sidecarURL)
            }
            let cacheSpy = ExtractorSpy()
            let cacheResolver = BookCoverResolver(
                storage: BookFileStorage(rootURL: root, bookStore: InMemoryBookStore(initial: [cacheBook]), coverExtractors: ["epub": cacheSpy]),
                isManagedReady: { _ in true }, isArtworkReadAllowed: { _ in true }
            )
            #expect(await cacheResolver.coverURL(for: cacheBook) == nil)
            #expect(await cacheSpy.callCount() == 0)
            try FileManager.default.removeItem(at: escapeSidecar ? sidecarURL : cacheURL)
            try? FileManager.default.removeItem(at: escapeSidecar ? cacheURL : sidecarURL)
        }
        #expect(try Data(contentsOf: sentinel) == sentinelData)
    }

    @Test("cache namespace anchor symlink is not accepted as a new cache root")
    func cacheAnchorSymlinkFailsClosed() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("CoverCacheAnchor-\(UUID().uuidString)", isDirectory: true)
        let outside = URL.temporaryDirectory.appendingPathComponent("CoverCacheAnchorOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Books", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Caches", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let cacheDirectory = root.appendingPathComponent("Caches/book-covers", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: cacheDirectory, withDestinationURL: outside)
        let owner = UUID()
        let book = Self.makeOwnedBook(owner: owner, coverPath: nil)
        let spy = ExtractorSpy()
        let storage = BookFileStorage(rootURL: root, bookStore: InMemoryBookStore(initial: [book]), coverExtractors: ["epub": spy])
        let resolver = BookCoverResolver(storage: storage, isManagedReady: { _ in true }, isArtworkReadAllowed: { _ in true })

        #expect(await resolver.coverURL(for: book) == nil)
        #expect(await spy.callCount() == 0)
    }

    @Test("raw cover and cached image aliases of an EPUB payload require managed readiness")
    func bookPayloadAliasesAreRejectedWhenManagedReadIsDenied() async throws {
        let owner = UUID()
        for kind in ["direct-path", "symlink", "hardlink", "cache-hardlink", "sidecar-hardlink"] {
            let root = URL.temporaryDirectory.appendingPathComponent("CoverPayloadAlias-\(kind)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
            let bookURL = root.appendingPathComponent(relativeBookPath)
            try FileManager.default.createDirectory(at: bookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("managed EPUB payload bytes".utf8).write(to: bookURL)
            let book: Book
            if kind == "direct-path" {
                book = Book(id: id, userId: owner, title: kind, formatType: .epub,
                            fileURL: relativeBookPath, coverPath: relativeBookPath)
            } else {
                let relativeCoverPath = (kind == "cache-hardlink" || kind == "sidecar-hardlink") ? nil : "Books/\(id.uuidString)/\(kind == "symlink" ? "cover-\(UUID().uuidString).png" : "cover.png")"
                book = Book(id: id, userId: owner, title: kind, formatType: .epub,
                            fileURL: relativeBookPath, coverPath: relativeCoverPath)
                if let relativeCoverPath {
                    let coverURL = root.appendingPathComponent(relativeCoverPath)
                if kind == "symlink" {
                    try FileManager.default.createSymbolicLink(at: coverURL, withDestinationURL: bookURL)
                } else if kind == "hardlink" {
                    try FileManager.default.linkItem(at: bookURL, to: coverURL)
                }
                }
            }

            let cacheDirectory = root.appendingPathComponent("Caches/book-covers", isDirectory: true)
            if kind == "cache-hardlink" || kind == "sidecar-hardlink" {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
                try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: bookURL.path)
                let cachedImage = cacheDirectory.appendingPathComponent("\(book.id.uuidString).heic")
                let sidecar = cacheDirectory.appendingPathComponent("\(book.id.uuidString).mtime")
                if kind == "cache-hardlink" {
                    try FileManager.default.linkItem(at: bookURL, to: cachedImage)
                    try Data(String(pinnedDate.timeIntervalSince1970).utf8).write(to: sidecar)
                } else {
                    try Self.makeValidPNG().write(to: cachedImage)
                    try FileManager.default.linkItem(at: bookURL, to: sidecar)
                }
            }

            let spy = ExtractorSpy()
            let storage = BookFileStorage(rootURL: root, bookStore: InMemoryBookStore(initial: [book]), coverExtractors: ["epub": spy])
            let resolver = BookCoverResolver(storage: storage, isManagedReady: { _ in false }, isArtworkReadAllowed: { _ in true })
            if kind == "sidecar-hardlink" {
                await #expect(throws: BookFileStorage.StorageError.self) {
                    try await storage.existingArtworkURL(for: book)
                }
            }
            #expect(await resolver.coverURL(for: book) == nil)
            #expect(await spy.callCount() == 0)
        }
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

    @MainActor
    @Test("bounded resolver prioritizes visible pending work and publishes explicit nil")
    func boundedResolverPrioritizesVisibleWork() async throws {
        let gate = CoverWorkGate()
        let books = (0..<5).map { Self.makeBook(title: "Bounded-\($0)") }
        let newlyVisible = books[4].id
        var visibleIDs: Set<BookID> = [books[2].id]
        var scheduledIDs: [BookID] = []
        var resolvedIDs: Set<BookID> = []
        var resolvedURLs: [BookID: URL] = [:]
        let resolver = BookCoverResolver(resolve: { await gate.resolve($0) })

        let work = Task { @MainActor in
            await resolver.resolveCoverURLs(
                for: books,
                maxConcurrent: 2,
                prioritizedBookIDs: { visibleIDs },
                onResolved: { id, url in
                    resolvedIDs.insert(id)
                    if let url { resolvedURLs[id] = url }
                },
                onScheduled: { scheduledIDs.append($0) }
            )
        }
        await gate.waitForStarts(2)
        let initial = await gate.snapshot()
        #expect(Array(scheduledIDs.prefix(2)) == [books[2].id, books[0].id])
        #expect(initial.active == 2)
        #expect(initial.maximumActive == 2)

        visibleIDs = [newlyVisible]
        await gate.release(initial.started[0])
        await gate.waitForStarts(3)
        let afterVisibilityChange = await gate.snapshot()
        #expect(scheduledIDs[2] == newlyVisible)
        #expect(afterVisibilityChange.maximumActive == 2)

        var released: Set<BookID> = [initial.started[0]]
        while true {
            let current = await gate.snapshot()
            for bookID in current.started where !released.contains(bookID) {
                released.insert(bookID)
                await gate.release(bookID, url: bookID == books[0].id ? nil : URL(fileURLWithPath: "/tmp/\(bookID.uuidString).heic"))
            }
            if current.started.count == books.count && current.active == 0 { break }
            await gate.waitForStarts(books.count)
        }
        await work.value
        #expect(resolvedIDs.count == books.count)
        #expect(resolvedURLs[books[0].id] == nil)
    }

    @MainActor
    @Test("canceled cover work does not publish a late result")
    func canceledCoverWorkDoesNotPublish() async {
        let gate = CoverWorkGate()
        let book = Self.makeBook(title: "Canceled")
        var resolvedIDs: Set<BookID> = []
        let resolver = BookCoverResolver(resolve: { await gate.resolve($0) })
        let work = Task { @MainActor in
            await resolver.resolveCoverURLs(
                for: [book],
                maxConcurrent: 1,
                prioritizedBookIDs: { [] },
                onResolved: { id, _ in resolvedIDs.insert(id) }
            )
        }

        await gate.waitForStarts(1)
        work.cancel()
        await gate.release(book.id, url: URL(fileURLWithPath: "/tmp/canceled.heic"))
        await work.value

        #expect(resolvedIDs.isEmpty)
        #expect((await gate.snapshot()).maximumActive == 1)
    }

    @MainActor
    @Test("visible work is selected only after a global permit opens")
    func queuedReplacementRechecksVisibilityAfterPermit() async {
        let gate = CoverWorkGate()
        let firstBooks = (0..<4).map { Self.makeBook(title: "Pass-A-\($0)") }
        let secondBooks = (0..<4).map { Self.makeBook(title: "Pass-B-\($0)") }
        let resolver = BookCoverResolver(resolve: { await gate.resolve($0) })
        let newlyVisibleID = secondBooks[3].id
        var visibleIDs: Set<BookID> = []
        var replacementSelections: [BookID] = []

        let firstPass = Task { @MainActor in
            await resolver.resolveCoverURLs(for: firstBooks, maxConcurrent: 4,
                                            prioritizedBookIDs: { [] }, onResolved: { _, _ in })
        }
        await gate.waitForStarts(4)
        let secondPass = Task { @MainActor in
            await resolver.resolveCoverURLs(for: secondBooks, maxConcurrent: 4,
                                            prioritizedBookIDs: { visibleIDs }, onResolved: { _, _ in },
                                            onScheduled: { replacementSelections.append($0) })
        }
        await resolver.waitForQueuedCoverJobs(4)
        let queued = await resolver.coverWorkCounts()
        #expect(queued.active == 4)
        #expect(queued.queued == 4)
        #expect(replacementSelections.isEmpty)
        #expect((await gate.snapshot()).maximumActive == 4)

        visibleIDs = [newlyVisibleID]
        await gate.release(firstBooks[0].id)
        await gate.waitForStarts(5)
        #expect(replacementSelections == [newlyVisibleID])
        #expect((await gate.snapshot()).started.last == newlyVisibleID)

        for book in firstBooks.dropFirst() { await gate.release(book.id) }
        await gate.waitForStarts(8)
        for book in secondBooks { await gate.release(book.id) }
        await firstPass.value
        await secondPass.value

        #expect((await gate.snapshot()).maximumActive == 4)
        #expect((await resolver.coverWorkCounts()).active == 0)
    }

    @MainActor
    @Test("a drained pass returns while unrelated gated cover work still owns permits")
    func drainedPassDoesNotWaitBehindUnrelatedWork() async {
        let gate = CoverWorkGate()
        let heldBooks = (0..<4).map { Self.makeBook(title: "Held-\($0)") }
        let quickBook = Self.makeBook(title: "Quick")
        let heldIDs = Set(heldBooks.map(\.id))
        var quickResults: Set<BookID> = []
        let resolver = BookCoverResolver(resolve: { book in
            if heldIDs.contains(book.id) { return await gate.resolve(book) }
            return URL(fileURLWithPath: "/tmp/quick.heic")
        })

        let heldPass = Task { @MainActor in
            await resolver.resolveCoverURLs(for: heldBooks, maxConcurrent: 4,
                                            prioritizedBookIDs: { [] }, onResolved: { _, _ in })
        }
        await gate.waitForStarts(4)
        let quickPass = Task { @MainActor in
            await resolver.resolveCoverURLs(for: [quickBook], maxConcurrent: 4,
                                            prioritizedBookIDs: { [] },
                                            onResolved: { id, _ in quickResults.insert(id) })
        }
        await resolver.waitForQueuedCoverJobs(4)

        await gate.release(heldBooks[0].id)
        await quickPass.value

        #expect(quickResults == [quickBook.id])
        #expect((await gate.snapshot()).active == 3)
        for book in heldBooks.dropFirst() { await gate.release(book.id) }
        await heldPass.value
    }
}
