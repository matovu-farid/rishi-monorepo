@testable import rishi
import Foundation
import Testing




/// Plan 34-17 — `BookImporter` owns the import orchestration extracted from
/// `BookFileStorage`. The pipeline is exhaustively covered through the
/// `BookFileStorage.importBook` facade (`BookFileStorageTests`,
/// `BookIndexingHookTests`); this suite locks in the new direct seam: driving
/// `BookImporter` on its own produces identical on-disk results, ids, and
/// upserts.
@Suite(.serialized)
struct BookImporterTests {

    private func makeTempRoot(_ label: String) -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("BookImporterTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImporter(
        rootURL: URL,
        bookStore: any BookStore,
        bookIndexingHook: any BookIndexingHook = NoopBookIndexingHook(),
        metadataExtractors: [String: any MetadataExtractor]? = nil,
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil
    ) -> BookImporter {
        BookImporter(
            rootURL: rootURL,
            booksDirURL: rootURL.appendingPathComponent("Books", isDirectory: true),
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ],
            metadataExtractors: metadataExtractors ?? [
                "pdf": PDFKitMetadataExtractor(),
                "epub": EpubMetadataExtractor()
            ],
            bookIndexingHook: bookIndexingHook,
            isTombstoned: isTombstoned
        )
    }

    @Test("importBook copies the file under Books/<id>/, writes a relative fileURL, and upserts")
    func importPDF_copiesFileAndPersistsBook() async throws {
        let root = makeTempRoot("import-pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-pdf-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcPDF = srcDir.appendingPathComponent("alice.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let userId = UUID()

        let book = try await importer.importBook(from: srcPDF, ownerId: userId)

        // Relative fileURL under Books/<id>/
        #expect(book.fileURL == "Books/\(book.id.uuidString)/alice.pdf")
        // File physically copied
        let abs = root.appendingPathComponent(book.fileURL)
        #expect(FileManager.default.fileExists(atPath: abs.path))
        // Row persisted
        let stored = try await store.book(book.id)
        #expect(stored?.id == book.id)
        #expect(stored?.userId == userId)
    }

    @Test("importBook throws unsupportedFormat for an unknown extension")
    func importUnsupported_throws() async throws {
        let root = makeTempRoot("import-unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-unsupported-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let bogus = srcDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: bogus)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)

        await #expect(throws: BookFileStorage.StorageError.self) {
            _ = try await importer.importBook(from: bogus, ownerId: UUID())
        }
    }

    @Test("importBook keeps different content separate even when metadata matches")
    func differentContent_sameMetadata_getsSeparateIdentity() async throws {
        let root = makeTempRoot("import-dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-dedup-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        // Same embedded metadata, different content -> separate identities.
        let srcA = srcDir.appendingPathComponent("alpha.epub")
        let srcB = srcDir.appendingPathComponent("beta.epub")
        try await FixtureBuilders.writeTinyEPUB(to: srcA, withCover: true)
        try await FixtureBuilders.writeTinyEPUB(to: srcB, withCover: false)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let userId = UUID()

        let bookA = try await importer.importBook(from: srcA, ownerId: userId)
        let bookB = try await importer.importBook(from: srcB, ownerId: userId)

        #expect(bookA.id != bookB.id, "Different content must not overwrite an existing book")
        #expect((await store.snapshot()).count == 2)
    }

    @Test("importBook deduplicates identical content even when metadata differs")
    func contentHash_deduplicatesDifferentMetadata() async throws {
        let root = makeTempRoot("import-content-hash")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-content-hash-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcA = srcDir.appendingPathComponent("first-copy.pdf")
        let srcB = srcDir.appendingPathComponent("second-copy.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcA)
        try FileManager.default.copyItem(at: srcA, to: srcB)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store, metadataExtractors: [:])
        let userId = UUID()

        let bookA = try await importer.importBook(from: srcA, ownerId: userId)
        let bookB = try await importer.importBook(from: srcB, ownerId: userId)

        #expect(bookB.id == bookA.id)
        #expect((await store.snapshot()).count == 1)
    }

    @Test("importBook preserves another user's deterministic book identity")
    func deterministicIdentityCollisionAcrossUsersRotatesIdentity() async throws {
        let root = makeTempRoot("import-cross-user-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-cross-user-collision-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let source = srcDir.appendingPathComponent("shared.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: true)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let firstUser = UUID()
        let secondUser = UUID()
        let firstBook = try await importer.importBook(from: source, ownerId: firstUser)
        let secondBook = try await importer.importBook(from: source, ownerId: secondUser)

        #expect(secondBook.id != firstBook.id)
        #expect(try await store.book(firstBook.id)?.userId == firstUser)
        #expect(try await store.book(secondBook.id)?.userId == secondUser)
        #expect((await store.snapshot()).count == 2)
    }

    @Test("importBook deduplicates concurrent copies of the same content")
    func concurrentImports_sameContent_createOneBook() async throws {
        let root = makeTempRoot("import-concurrent-dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-concurrent-dedup-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcA = srcDir.appendingPathComponent("copy-a.pdf")
        let srcB = srcDir.appendingPathComponent("copy-b.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcA)
        try FileManager.default.copyItem(at: srcA, to: srcB)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store, metadataExtractors: [:])
        let userId = UUID()
        let imported = try await withThrowingTaskGroup(of: Book.self, returning: [Book].self) { group in
            group.addTask { try await importer.importBook(from: srcA, ownerId: userId) }
            group.addTask { try await importer.importBook(from: srcB, ownerId: userId) }
            var books: [Book] = []
            for try await book in group {
                books.append(book)
            }
            return books
        }

        #expect(imported.count == 2)
        #expect(Set(imported.map(\.id)).count == 1)
        #expect((await store.snapshot()).count == 1)
    }

    @Test("importBook rotates identity when the deterministic candidate is tombstoned")
    func tombstonedDeterministicIdReceivesFreshIdentity() async throws {
        let root = makeTempRoot("import-tombstone")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-tombstone-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let source = srcDir.appendingPathComponent("thinking-in-bets.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: true)

        let store = InMemoryBookStore()
        let original = try await makeImporter(rootURL: root, bookStore: store)
            .importBook(from: source, ownerId: UUID())
        let reimported = try await makeImporter(
            rootURL: root,
            bookStore: store,
            isTombstoned: { candidate in candidate == original.id }
        ).importBook(from: source, ownerId: original.userId)

        #expect(reimported.id != original.id)
        #expect(try await store.book(reimported.id)?.id == reimported.id)
    }
}
