import Testing
import Foundation
import ReadiumShared
@testable import RishiReader

@Suite("PublicationLoader", .serialized)
struct PublicationLoaderTests {

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    @Test("opens bundled alice.epub and returns a publication with a title")
    func opensBundledAlice() async throws {
        let url = try aliceURL()
        let loader = PublicationLoader()
        let publication = try await loader.open(fileURL: url)
        let title = publication.metadata.title ?? ""
        #expect(!title.isEmpty)
        // Project Gutenberg #11 — Alice's Adventures in Wonderland
        #expect(title.lowercased().contains("alice"))
    }

    @Test("opening a non-existent file throws")
    func nonExistentFileThrows() async {
        let bad = URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).epub")
        let loader = PublicationLoader()
        await #expect(throws: (any Error).self) {
            _ = try await loader.open(fileURL: bad)
        }
    }

    @Test("publication exposes a table of contents")
    func publicationHasTOC() async throws {
        let url = try aliceURL()
        let loader = PublicationLoader()
        let publication = try await loader.open(fileURL: url)
        let toc = publication.manifest.tableOfContents
        #expect(toc.count > 0)
    }
}
