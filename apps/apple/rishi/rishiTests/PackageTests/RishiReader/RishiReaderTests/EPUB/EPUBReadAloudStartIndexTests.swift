@testable import rishi
import Testing
import PropertyBased
import Foundation
import ReadiumShared




/// Bug 2 (read-aloud starts from page 1): pressing Play on a forwarded page
/// must begin read-aloud at the FIRST paragraph of the CURRENT page, not at
/// paragraph 0 of the resource.
///
/// Property: forall progression P in a resource chunked into N paragraphs,
/// `paragraphsForReadAloud()` returns the SLICE beginning at
/// `ParagraphChunker.startIndex(forProgression: P, count: N)` — i.e. its first
/// element equals `allParagraphs[startIndex(P)]`. The old implementation
/// returned `allParagraphs` unconditionally (start always 0), so for any P > 0
/// that lands past paragraph 0 the first spoken paragraph is wrong.
@Suite("EPUB read-aloud start index", .serialized)
struct EPUBReadAloudStartIndexTests {

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    private func purpleCowURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "purple-cow", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Fixture", formatType: .epub, fileURL: "Books/x/fixture.epub")
    }

    @MainActor
    private func loadedVM(url: URL) async throws -> ReaderViewModel {
        let vm = ReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 5.0
        )
        await vm.load()
        _ = try #require(vm.publication)
        return vm
    }

    private func makeLocator(link: ReadiumShared.Link, progression: Double) throws -> Locator {
        let href = try #require(RelativeURL(path: link.href))
        return Locator(
            href: href,
            mediaType: link.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: progression, totalProgression: progression)
        )
    }

    /// Find the first reading-order resource that yields >= 3 paragraphs, so
    /// the property has real prose to slice (covers / nav docs / blank title
    /// pages have too few paragraphs to exercise the start-index math).
    @MainActor
    private func firstContentLink(vm: ReaderViewModel, publication: Publication) async throws -> ReadiumShared.Link {
        for link in publication.readingOrder {
            let loc = try makeLocator(link: link, progression: 0)
            vm.didChangeLocation(loc)
            let paragraphs = await vm.paragraphsForReadAloud()
            if paragraphs.count >= 3 { return link }
        }
        Issue.record("no reading-order resource produced >= 3 paragraphs")
        throw FixtureLookupError.noContentResource
    }

    enum FixtureLookupError: Error { case noContentResource }

    /// Core property check for one epub: across a spread of progressions, the
    /// first returned paragraph must equal the expected paragraph at the
    /// progression-derived start index of the resource's full chunk list.
    @MainActor
    private func assertStartParagraphMatchesPage(url: URL) async throws {
        let vm = try await loadedVM(url: url)
        let publication = try #require(vm.publication)
        let link = try await firstContentLink(vm: vm, publication: publication)

        // Ground truth: the full paragraph list for the chosen resource at
        // progression 0 (= whole resource, start index 0).
        let loc0 = try makeLocator(link: link, progression: 0)
        vm.didChangeLocation(loc0)
        let allParagraphs = await vm.paragraphsForReadAloud()
        try #require(allParagraphs.count >= 3,
                     "content resource must have several paragraphs to exercise the property; got \(allParagraphs.count)")

        // Property (PropertyBased): forall progression P generated in [0, 1],
        // paragraphsForReadAloud() returns the tail slice beginning at
        // allParagraphs[startIndex(P)]. Generated + shrunk rather than a fixed
        // stride, over the real publication. count kept modest because each
        // iteration re-reads + re-chunks the resource.
        await propertyCheck(count: 40, input: Gen.double(in: 0.0 ... 1.0)) { progression in
            let loc = try makeLocator(link: link, progression: progression)
            vm.didChangeLocation(loc)
            let fromPage = await vm.paragraphsForReadAloud()

            let expectedStart = ParagraphChunker.startIndex(
                forProgression: progression,
                count: allParagraphs.count
            )
            let expectedParagraph = allParagraphs[expectedStart]

            #expect(fromPage.first == expectedParagraph,
                    "progression \(progression): read-aloud must start at paragraph index \(expectedStart) (\"\(expectedParagraph.prefix(40))...\"), got \"\(fromPage.first?.prefix(40) ?? "nil")...\"")
            #expect(fromPage.count == allParagraphs.count - expectedStart,
                    "progression \(progression): returned slice length must be the tail from \(expectedStart)")
        }
    }

    @Test("alice: Play on a forwarded page starts at that page's first paragraph")
    @MainActor
    func aliceStartsAtCurrentPage() async throws {
        try await assertStartParagraphMatchesPage(url: aliceURL())
    }

    @Test("purple-cow: Play on a forwarded page starts at that page's first paragraph")
    @MainActor
    func purpleCowStartsAtCurrentPage() async throws {
        try await assertStartParagraphMatchesPage(url: purpleCowURL())
    }
}
