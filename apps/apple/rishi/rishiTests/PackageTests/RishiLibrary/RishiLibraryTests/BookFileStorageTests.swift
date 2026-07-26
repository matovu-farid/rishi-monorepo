@testable import rishi
import Foundation
import Testing




/// Test-only `MetadataExtractor` that returns fixed metadata regardless of the
/// source file — lets us drive the deterministic-id path from distinct fixtures.
private struct StubMetadataExtractor: MetadataExtractor {
    let title: String?
    let author: String?

    func extractMetadata(from fileURL: URL) async -> BookMetadata {
        BookMetadata(title: title, author: author)
    }
}

@Suite(.serialized)
struct BookFileStorageTests {

    private func makeTempRoot(_ label: String) -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("BookFileStorageTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStorage(rootURL: URL, bookStore: any BookStore) -> BookFileStorage {
        BookFileStorage(
            rootURL: rootURL,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ],
            metadataExtractors: [
                "pdf": PDFKitMetadataExtractor(),
                "epub": EpubMetadataExtractor()
            ]
        )
    }

    /// Regression: the user reported imports landing as
    /// `1751655520501062500_alice.epub` with `Book.title` set to that
    /// filename instead of the embedded `<dc:title>`. The metadata extractor
    /// must override the filename whenever the OPF carries a non-empty title.
    @Test
    func importEPUB_usesEmbeddedDCTitleOverFilename() async throws {
        let root = makeTempRoot("import-epub-dctitle")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-epub-dctitle-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        // FixtureBuilders.writeTinyEPUB writes `<dc:title>Fixture Title</dc:title>`.
        let srcEPUB = srcDir.appendingPathComponent("1751655520501062500_alice.epub")
        try await FixtureBuilders.writeTinyEPUB(to: srcEPUB, withCover: true)

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
        let book = try await storage.importBook(from: srcEPUB, ownerId: UUID())

        #expect(book.title == "Fixture Title")
        // Author absent from fixture OPF — should be nil rather than filename.
        #expect(book.author == nil)
    }

    @Test
    func importPDF_copiesFileExtractsCoverAndPersistsBook() async throws {
        let root = makeTempRoot("import-pdf")
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = makeTempRoot("import-pdf-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcPDF = srcDir.appendingPathComponent("alice.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
        let userId = UUID()

        let book = try await storage.importBook(from: srcPDF, ownerId: userId)

        // File copied
        let absoluteFileURL = await storage.absoluteFileURL(for: book)
        #expect(FileManager.default.fileExists(atPath: absoluteFileURL.path))
        #expect(absoluteFileURL.lastPathComponent == "alice.pdf")

        // Book row persisted
        let stored = try await store.book(book.id)
        #expect(stored?.id == book.id)
        #expect(stored?.userId == userId)
        #expect(stored?.formatType == .pdf)

        // Cover extracted
        #expect(book.coverPath != nil)
        let coverURL = await storage.cachedCoverURL(for: book)
        #expect(coverURL != nil)
        if let coverURL {
            #expect(FileManager.default.fileExists(atPath: coverURL.path))
        }
    }

    @Test
    func importEPUB_storesBookWithCover() async throws {
        let root = makeTempRoot("import-epub")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-epub-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcEPUB = srcDir.appendingPathComponent("alice.epub")
        try await FixtureBuilders.writeTinyEPUB(to: srcEPUB, withCover: true)

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
        let userId = UUID()

        let book = try await storage.importBook(from: srcEPUB, ownerId: userId)
        #expect(book.formatType == .epub)
        #expect(book.coverPath != nil)
    }

    @Test
    func importUnsupportedExtension_throws() async throws {
        let root = makeTempRoot("import-bad")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-bad-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let bogus = srcDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: bogus)

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)

        await #expect(throws: BookFileStorage.StorageError.self) {
            _ = try await storage.importBook(from: bogus, ownerId: UUID())
        }
    }

    @Test
    func delete_removesFileAndStoreRow() async throws {
        let root = makeTempRoot("delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("delete-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcPDF = srcDir.appendingPathComponent("doc.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
        let book = try await storage.importBook(from: srcPDF, ownerId: UUID())

        // Sanity
        let absoluteFileURL = await storage.absoluteFileURL(for: book)
        #expect(FileManager.default.fileExists(atPath: absoluteFileURL.path))

        try await storage.delete(book)

        #expect(!FileManager.default.fileExists(atPath: absoluteFileURL.path))
        let stored = try await store.book(book.id)
        #expect(stored == nil)
    }

    /// Core dedup guarantee: two source files with the SAME embedded
    /// title+author+format but DIFFERENT filenames must produce the SAME
    /// `Book.id` so they collapse to one library entry after sync upsert.
    @Test
    func importSameMetadataDifferentFilenames_yieldsEqualBookIds() async throws {
        let root = makeTempRoot("dedup-id")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("dedup-id-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let srcA = srcDir.appendingPathComponent("alice_v1.pdf")
        let srcB = srcDir.appendingPathComponent("9876543_alice.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcA)
        try FixtureBuilders.writeTinyPDF(to: srcB)

        let store = InMemoryBookStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: store,
            coverExtractors: [:],
            metadataExtractors: [
                "pdf": StubMetadataExtractor(title: "Alice in Wonderland", author: "Lewis Carroll")
            ]
        )

        let userId = UUID()
        let bookA = try await storage.importBook(from: srcA, ownerId: userId)
        let bookB = try await storage.importBook(from: srcB, ownerId: userId)

        #expect(bookA.id == bookB.id)
    }

    /// A book with NO embedded title falls back to a random UUID id — import
    /// must still succeed and produce a usable (non-nil) row.
    @Test
    func importWithNoEmbeddedTitle_fallsBackToRandomIdAndSucceeds() async throws {
        let root = makeTempRoot("no-title-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("no-title-fallback-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcPDF = srcDir.appendingPathComponent("untitled.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let store = InMemoryBookStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: store,
            coverExtractors: [:],
            metadataExtractors: [
                "pdf": StubMetadataExtractor(title: nil, author: nil)
            ]
        )

        let book = try await storage.importBook(from: srcPDF, ownerId: UUID())
        let stored = try await store.book(book.id)
        #expect(stored?.id == book.id)
    }

    @Test
    func cachedCoverURL_returnsNilWhenCoverPathIsNilAndSourceMissing() async throws {
        let root = makeTempRoot("cached-nil")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
        // Source file does not exist on disk -> extractor returns nil ->
        // cache returns nil -> cachedCoverURL returns nil.
        let bookWithoutCover = Book(
            userId: UUID(),
            title: "X",
            formatType: .pdf,
            fileURL: "Books/none/x.pdf",
            coverPath: nil
        )
        let url = await storage.cachedCoverURL(for: bookWithoutCover)
        #expect(url == nil)
    }

    /// Phase 21 follow-up — when `coverPath` exists, the cache should be
    /// populated on first call and re-used (no re-encode) on subsequent
    /// calls. This is the load-bearing fix for "covers take forever to come
    /// in" — the cache file MUST sit under `Caches/book-covers/<bookID>.heic`
    /// after the first paint so subsequent paints are instant.
    @Test
    func cachedCoverURL_populatesDownsampledCache_whenCoverPathExists() async throws {
        let root = makeTempRoot("cached-downsample")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)

        // Import a real PDF so a real `cover.png` lands on disk.
        let srcDir = makeTempRoot("cached-downsample-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcPDF = srcDir.appendingPathComponent("doc.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)
        let book = try await storage.importBook(from: srcPDF, ownerId: UUID())
        #expect(book.coverPath != nil)

        // First call — populates the downsampled HEIC cache.
        let first = await storage.cachedCoverURL(for: book)
        #expect(first != nil)

        // The cache file should now exist under
        // `<root>/Caches/book-covers/<bookID>.heic` (or .heic with a PNG
        // fallback body on simulators that can't encode HEIC — either way
        // it's at the same path).
        let cacheURL = root
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("book-covers", isDirectory: true)
            .appendingPathComponent("\(book.id.uuidString).heic")
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // The returned URL on a tile paint should be the downsampled cache
        // (NOT the original full-resolution `cover.png`) so AsyncImage
        // decodes the small thumbnail instead of the multi-megapixel source.
        #expect(first?.path == cacheURL.path)

        // Second call — pure cache hit. Same path, no re-encode work.
        let second = await storage.cachedCoverURL(for: book)
        #expect(second?.path == cacheURL.path)
    }

    /// Phase 21: rescue path for books imported before the EPUB extractor
    /// was robust. DB row has `coverPath == nil`, but the on-disk file IS a
    /// valid EPUB with a cover — `cachedCoverURL` should lazily extract,
    /// persist to the disk cache, and return a usable URL.
    @Test
    func cachedCoverURL_lazilyExtractsWhenCoverPathNilButSourceValid() async throws {
        let root = makeTempRoot("cached-lazy")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)

        // Build an EPUB inside the storage root at a known relative path so
        // `BookFileStorage.absoluteFileURL(for:)` resolves correctly.
        let booksDir = root.appendingPathComponent("Books/legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        let epubURL = booksDir.appendingPathComponent("legacy.epub")
        try await FixtureBuilders.writeTinyEPUB(to: epubURL, withCover: true)

        let legacyBook = Book(
            userId: UUID(),
            title: "Legacy",
            formatType: .epub,
            fileURL: "Books/legacy/legacy.epub",
            coverPath: nil
        )

        let url = await storage.cachedCoverURL(for: legacyBook)
        #expect(url != nil)
        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
