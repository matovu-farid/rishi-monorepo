@testable import rishi
import Foundation
import ReadiumShared



import Testing


@Suite("Imported book lifecycle", .serialized)
struct ImportedBookLifecycleTests {

    private enum FixtureError: Error {
        case noReadableContent
    }

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeTempRoot() -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("ImportedBookLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStorage(rootURL: URL, bookStore: any BookStore) -> BookFileStorage {
        BookFileStorage(
            rootURL: rootURL,
            bookStore: bookStore,
            coverExtractors: [:]
        )
    }

    private func makeLocator(link: ReadiumShared.Link) throws -> Locator {
        let href = try #require(RelativeURL(path: link.href))
        return Locator(
            href: href,
            mediaType: link.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0, totalProgression: 0)
        )
    }

    @MainActor
    private func firstReadableParagraph(in vm: ReaderViewModel) async throws -> String {
        let publication = try #require(vm.publication)
        for link in publication.readingOrder {
            vm.didChangeLocation(try makeLocator(link: link))
            if let paragraph = await vm.paragraphsForReadAloud().first,
               !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return paragraph
            }
        }
        throw FixtureError.noReadableContent
    }

    @Test("imports a real EPUB, reads it from the imported copy, and deletes it")
    @MainActor
    func importsReadsAndDeletesRealEPUB() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SampleInMemoryBookStore()
        let storage = makeStorage(rootURL: root, bookStore: store)
        let book = try await storage.importBook(from: aliceURL(), ownerId: UUID())
        let importedURL = storage.absoluteFileURL(for: book)

        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        #expect(PublicationLoader.bookId(forFileURL: importedURL) == book.id)

        let vm = ReaderViewModel(
            book: book,
            userId: book.userId,
            documentURL: importedURL,
            positionStore: InMemoryPositionStore(),
            loader: PublicationLoader(unpackedCache: nil),
            debounceSeconds: 5.0
        )
        await vm.load()

        #expect(vm.publication?.metadata.title?.lowercased().contains("alice") == true)
        let paragraph = try await firstReadableParagraph(in: vm)
        #expect(paragraph.lowercased().contains("alice"))

        try await storage.delete(book)

        #expect(!FileManager.default.fileExists(atPath: importedURL.path))
        let stored = try await store.book(book.id)
        #expect(stored == nil)
    }
}
