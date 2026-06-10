import Foundation
import Testing
import RishiCore
import RishiTesting
@testable import RishiLibrary

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
            ]
        )
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

    @Test
    func cachedCoverURL_returnsNilWhenCoverPathIsNil() async throws {
        let root = makeTempRoot("cached")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
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
}
