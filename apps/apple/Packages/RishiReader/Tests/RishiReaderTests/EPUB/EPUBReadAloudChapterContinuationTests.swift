import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiTesting
@testable import RishiReader

/// Chapter-boundary continuation (read-aloud crossing chapters): when narration
/// finishes the last paragraph of one reading-order resource (chapter), the
/// reader must be able to hand the NEXT chapter's paragraphs to the TTS bridge
/// so playback continues instead of halting. `paragraphsForFollowingResource()`
/// is the source for that next batch.
///
/// Reproduces the reported bug on the multi-chapter `rationality.epub` (and
/// `alice.epub`): before the fix `paragraphsForFollowingResource()` returns
/// `[]`, so the bridge tears down at the chapter boundary and the audio stops.
@Suite("EPUB read-aloud chapter continuation", .serialized)
struct EPUBReadAloudChapterContinuationTests {

    private func rationalityURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "rationality", withExtension: "epub"))
    }

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Fixture", formatType: .epub, fileURL: "Books/x/fixture.epub")
    }

    @MainActor
    private func loadedVM(url: URL) async throws -> EPUBReaderViewModel {
        let vm = EPUBReaderViewModel(
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

    /// Anchor the read-aloud cursor on `link` and return that resource's full
    /// paragraph list (progression 0 slices the whole resource).
    @MainActor
    private func paragraphs(of link: ReadiumShared.Link, vm: EPUBReaderViewModel) async throws -> [String] {
        vm.didChangeLocation(try makeLocator(link: link, progression: 0))
        return await vm.paragraphsForReadAloud()
    }

    /// Reading-order indices whose resource chunks to at least one paragraph
    /// (skips covers / nav docs / blank section breaks).
    @MainActor
    private func nonEmptyContentIndices(vm: EPUBReaderViewModel, publication: Publication) async throws -> [Int] {
        var indices: [Int] = []
        for (i, link) in publication.readingOrder.enumerated() {
            if !(try await paragraphs(of: link, vm: vm)).isEmpty {
                indices.append(i)
            }
        }
        return indices
    }

    /// Core property: from the chapter read-aloud is narrating,
    /// `paragraphsForFollowingResource()` returns the NEXT non-empty chapter's
    /// FULL paragraph list — completeness, not merely non-empty.
    @MainActor
    private func assertContinuesIntoNextChapter(url: URL) async throws {
        let vm = try await loadedVM(url: url)
        let publication = try #require(vm.publication)
        let order = publication.readingOrder

        let content = try await nonEmptyContentIndices(vm: vm, publication: publication)
        try #require(content.count >= 2, "fixture must have >= 2 non-empty chapters to cross a boundary")

        let chapterAIndex = content[0]
        let chapterBIndex = content[1]
        // Ground truth for the next chapter's paragraphs, captured independently.
        let expectedNext = try await paragraphs(of: order[chapterBIndex], vm: vm)
        let chapterBLeaf = try #require(order[chapterBIndex].href.split(separator: "/").last.map(String.init))

        // Anchor the cursor on chapter A (the resource being narrated), then ask
        // for the following resource.
        _ = try await paragraphs(of: order[chapterAIndex], vm: vm)
        let following = await vm.paragraphsForFollowingResource()

        #expect(!following.isEmpty,
                "read-aloud must continue into the next chapter, not stop at the chapter boundary")
        #expect(following == expectedNext,
                "following resource must be chapter B's complete paragraph list (skipping any empty resources between A and B)")
        // The live locator must advance into chapter B so the text-anchored
        // read-aloud follow turns the page into the new chapter (not just audio).
        let landedHref = String(describing: vm.latestLocator?.href)
        #expect(landedHref.contains(chapterBLeaf),
                "latestLocator must move into chapter B (\(chapterBLeaf)) so the page follows; got \(landedHref)")
    }

    /// At the end of the book the source dries up: `paragraphsForFollowingResource()`
    /// returns `[]`, which the bridge interprets as "stop".
    @MainActor
    private func assertStopsAtEndOfBook(url: URL) async throws {
        let vm = try await loadedVM(url: url)
        let publication = try #require(vm.publication)
        let order = publication.readingOrder

        let content = try await nonEmptyContentIndices(vm: vm, publication: publication)
        let lastContentIndex = try #require(content.last)

        // Anchor on the last chapter with prose; there is no further chapter.
        _ = try await paragraphs(of: order[lastContentIndex], vm: vm)
        let following = await vm.paragraphsForFollowingResource()

        #expect(following.isEmpty, "no chapter follows the last one — must return [] so playback stops")
    }

    @Test("rationality: read-aloud continues into the next chapter")
    @MainActor
    func rationalityContinuesIntoNextChapter() async throws {
        try await assertContinuesIntoNextChapter(url: rationalityURL())
    }

    @Test("rationality: read-aloud stops at the end of the book")
    @MainActor
    func rationalityStopsAtEndOfBook() async throws {
        try await assertStopsAtEndOfBook(url: rationalityURL())
    }

    @Test("alice: read-aloud continues into the next chapter")
    @MainActor
    func aliceContinuesIntoNextChapter() async throws {
        try await assertContinuesIntoNextChapter(url: aliceURL())
    }
}
