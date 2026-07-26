@testable import rishi
import Testing
import Foundation
import ReadiumShared




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
        try #require(PackageTestResourceBundle.bundle.url(forResource: "rationality", withExtension: "epub"))
    }

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
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

    /// Anchor the read-aloud cursor on `link` and return that resource's full
    /// paragraph list (progression 0 slices the whole resource).
    @MainActor
    private func paragraphs(of link: ReadiumShared.Link, vm: ReaderViewModel) async throws -> [String] {
        vm.didChangeLocation(try makeLocator(link: link, progression: 0))
        return await vm.paragraphsForReadAloud()
    }

    /// Reading-order indices whose resource chunks to at least one paragraph
    /// (skips covers / nav docs / blank section breaks).
    @MainActor
    private func nonEmptyContentIndices(vm: ReaderViewModel, publication: Publication) async throws -> [Int] {
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

    /// Backward parity: from the chapter read-aloud is narrating,
    /// `paragraphsForPrecedingResource()` returns the PREVIOUS non-empty chapter's
    /// FULL paragraph list (completeness, not merely non-empty), and moves the
    /// live locator back into it so the page follows.
    @MainActor
    private func assertContinuesIntoPreviousChapter(url: URL) async throws {
        let vm = try await loadedVM(url: url)
        let publication = try #require(vm.publication)
        let order = publication.readingOrder

        let content = try await nonEmptyContentIndices(vm: vm, publication: publication)
        try #require(content.count >= 2, "fixture must have >= 2 non-empty chapters to cross a boundary")

        let chapterAIndex = content[0]
        let chapterBIndex = content[1]
        // Ground truth for the previous chapter's paragraphs, captured independently.
        let expectedPrev = try await paragraphs(of: order[chapterAIndex], vm: vm)
        let chapterALeaf = try #require(order[chapterAIndex].href.split(separator: "/").last.map(String.init))

        // Anchor the cursor on chapter B (the resource being narrated), then ask
        // for the preceding resource.
        _ = try await paragraphs(of: order[chapterBIndex], vm: vm)
        let preceding = await vm.paragraphsForPrecedingResource()

        #expect(!preceding.isEmpty,
                "read-aloud must continue into the previous chapter, not stop at the chapter boundary")
        #expect(preceding == expectedPrev,
                "preceding resource must be chapter A's complete paragraph list (skipping any empty resources between A and B)")
        let landedHref = String(describing: vm.latestLocator?.href)
        #expect(landedHref.contains(chapterALeaf),
                "latestLocator must move back into chapter A (\(chapterALeaf)) so the page follows; got \(landedHref)")
    }

    /// At the start of the book the backward source dries up:
    /// `paragraphsForPrecedingResource()` returns `[]`, which the bridge
    /// interprets as "stay put".
    @MainActor
    private func assertStopsAtStartOfBook(url: URL) async throws {
        let vm = try await loadedVM(url: url)
        let publication = try #require(vm.publication)
        let order = publication.readingOrder

        let content = try await nonEmptyContentIndices(vm: vm, publication: publication)
        let firstContentIndex = try #require(content.first)

        // Anchor on the first chapter with prose; there is no preceding chapter.
        _ = try await paragraphs(of: order[firstContentIndex], vm: vm)
        let preceding = await vm.paragraphsForPrecedingResource()

        #expect(preceding.isEmpty, "no chapter precedes the first one — must return [] so playback stays put")
    }

    @Test("rationality: read-aloud continues into the next chapter")
    @MainActor
    func rationalityContinuesIntoNextChapter() async throws {
        try await assertContinuesIntoNextChapter(url: rationalityURL())
    }

    @Test("rationality: read-aloud continues into the previous chapter")
    @MainActor
    func rationalityContinuesIntoPreviousChapter() async throws {
        try await assertContinuesIntoPreviousChapter(url: rationalityURL())
    }

    @Test("rationality: read-aloud stays put at the start of the book")
    @MainActor
    func rationalityStaysPutAtStartOfBook() async throws {
        try await assertStopsAtStartOfBook(url: rationalityURL())
    }

    @Test("alice: read-aloud continues into the previous chapter")
    @MainActor
    func aliceContinuesIntoPreviousChapter() async throws {
        try await assertContinuesIntoPreviousChapter(url: aliceURL())
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
