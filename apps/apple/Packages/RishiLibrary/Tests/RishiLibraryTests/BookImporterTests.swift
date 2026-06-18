import Foundation
import Testing
@testable import RishiLibrary
import RishiCore
import RishiTesting

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
        bookIndexingHook: any BookIndexingHook = NoopBookIndexingHook()
    ) -> BookImporter {
        BookImporter(
            rootURL: rootURL,
            booksDirURL: rootURL.appendingPathComponent("Books", isDirectory: true),
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ],
            metadataExtractors: [
                "pdf": PDFKitMetadataExtractor(),
                "epub": EpubMetadataExtractor()
            ],
            bookIndexingHook: bookIndexingHook
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

    @Test("importBook mints deterministic ids — same metadata across filenames collapses to one id")
    func deterministicId_collapsesAcrossFilenames() async throws {
        let root = makeTempRoot("import-dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-dedup-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        // Same embedded metadata, different filenames -> same deterministic id.
        let srcA = srcDir.appendingPathComponent("alpha.epub")
        let srcB = srcDir.appendingPathComponent("beta.epub")
        try await FixtureBuilders.writeTinyEPUB(to: srcA, withCover: true)
        try await FixtureBuilders.writeTinyEPUB(to: srcB, withCover: true)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let userId = UUID()

        let bookA = try await importer.importBook(from: srcA, ownerId: userId)
        let bookB = try await importer.importBook(from: srcB, ownerId: userId)

        #expect(bookA.id == bookB.id, "Identical metadata must collapse to one deterministic id")
    }
}
