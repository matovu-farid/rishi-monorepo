@testable import rishi
import Testing
import Foundation
import ReadiumShared




/// Direct unit tests for ``EPUBReadAloudCursor`` — the read-aloud
/// resource/page parsing + chapter-continuation cursor extracted from
/// ``ReaderViewModel`` (plan 34-06).
///
/// These assert the cursor's NEW explicit contract: forward/backward chapter
/// walks return a `navigateTo` locator INTENT (the VM applies it to
/// `latestLocator`) instead of the cursor reaching back into the VM. The
/// behavior of the slice + boundary skipping is also covered transitively
/// through the VM facade in `EPUBReadAloudChapterContinuationTests` /
/// `EPUBReadAloudStartIndexTests`; this suite pins the seam directly.
@Suite("EPUBReadAloudCursor", .serialized)
struct EPUBReadAloudCursorTests {

    private func rationalityURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "rationality", withExtension: "epub"))
    }

    private func loadedPublication(url: URL) async throws -> Publication {
        try await PublicationLoader().open(fileURL: url)
    }

    private func makeLocator(link: ReadiumShared.Link, progression: Double) throws -> Locator {
        let href = try #require(RelativeURL(path: link.href))
        return Locator(
            href: href,
            mediaType: link.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: progression, totalProgression: progression)
        )
    }

    /// Reading-order indices whose resource chunks to >= 1 paragraph. Anchors
    /// the cursor on each in turn (fresh cursor) to classify content chapters.
    private func nonEmptyContentIndices(publication: Publication) async throws -> [Int] {
        var indices: [Int] = []
        for (i, link) in publication.readingOrder.enumerated() {
            let cursor = EPUBReadAloudCursor(publication: publication)
            let loc = try makeLocator(link: link, progression: 0)
            let result = await cursor.paragraphsAtCurrentPage(locator: loc)
            if !result.paragraphs.isEmpty { indices.append(i) }
        }
        return indices
    }

    @Test("current page parse never requests a navigation")
    func currentPageHasNoNavigateIntent() async throws {
        let publication = try await loadedPublication(url: rationalityURL())
        let content = try await nonEmptyContentIndices(publication: publication)
        let firstContent = try #require(content.first)

        let cursor = EPUBReadAloudCursor(publication: publication)
        let loc = try makeLocator(link: publication.readingOrder[firstContent], progression: 0)
        let result = await cursor.paragraphsAtCurrentPage(locator: loc)

        #expect(!result.paragraphs.isEmpty)
        #expect(result.navigateTo == nil,
                "the reader is already on this page — the cursor must not request a navigation")
    }

    @Test("following resource returns paragraphs plus a navigate-into-next-chapter intent")
    func followingEmitsNavigateIntent() async throws {
        let publication = try await loadedPublication(url: rationalityURL())
        let order = publication.readingOrder
        let content = try await nonEmptyContentIndices(publication: publication)
        try #require(content.count >= 2, "fixture must have >= 2 non-empty chapters")

        let chapterAIndex = content[0]
        let chapterBIndex = content[1]
        let chapterBLeaf = try #require(order[chapterBIndex].href.split(separator: "/").last.map(String.init))

        // Anchor the cursor on chapter A, then ask for the following resource.
        let cursor = EPUBReadAloudCursor(publication: publication)
        _ = await cursor.paragraphsAtCurrentPage(locator: try makeLocator(link: order[chapterAIndex], progression: 0))
        let following = await cursor.paragraphsFollowing(fallbackLocator: nil)

        #expect(!following.paragraphs.isEmpty,
                "must continue into the next chapter, not stop at the boundary")
        let navHref = String(describing: following.navigateTo?.href)
        #expect(following.navigateTo != nil, "crossing a chapter boundary must emit a navigate intent")
        #expect(navHref.contains(chapterBLeaf),
                "navigate intent must point into chapter B (\(chapterBLeaf)); got \(navHref)")
    }

    @Test("following at the end of the book returns empty with no navigate intent")
    func followingStopsAtEndOfBook() async throws {
        let publication = try await loadedPublication(url: rationalityURL())
        let order = publication.readingOrder
        let content = try await nonEmptyContentIndices(publication: publication)
        let lastContent = try #require(content.last)

        let cursor = EPUBReadAloudCursor(publication: publication)
        _ = await cursor.paragraphsAtCurrentPage(locator: try makeLocator(link: order[lastContent], progression: 0))
        let following = await cursor.paragraphsFollowing(fallbackLocator: nil)

        #expect(following.paragraphs.isEmpty, "no chapter follows the last — must return empty")
        #expect(following.navigateTo == nil, "no navigation when there is no next chapter")
    }

    @Test("preceding at the start of the book returns empty with no navigate intent")
    func precedingStaysPutAtStartOfBook() async throws {
        let publication = try await loadedPublication(url: rationalityURL())
        let order = publication.readingOrder
        let content = try await nonEmptyContentIndices(publication: publication)
        let firstContent = try #require(content.first)

        let cursor = EPUBReadAloudCursor(publication: publication)
        _ = await cursor.paragraphsAtCurrentPage(locator: try makeLocator(link: order[firstContent], progression: 0))
        let preceding = await cursor.paragraphsPreceding(fallbackLocator: nil)

        #expect(preceding.paragraphs.isEmpty, "no chapter precedes the first — must return empty")
        #expect(preceding.navigateTo == nil, "no navigation when there is no previous chapter")
    }

    @Test("cursor falls back to the supplied locator before any current-page parse")
    func fallbackLocatorBeforeFirstParse() async throws {
        let publication = try await loadedPublication(url: rationalityURL())
        let order = publication.readingOrder
        let content = try await nonEmptyContentIndices(publication: publication)
        try #require(content.count >= 2)
        let chapterAIndex = content[0]

        // No paragraphsAtCurrentPage() call first: the cursor must use the
        // fallback locator (the live VM locator) to seed its position.
        let cursor = EPUBReadAloudCursor(publication: publication)
        let fallback = try makeLocator(link: order[chapterAIndex], progression: 0)
        let following = await cursor.paragraphsFollowing(fallbackLocator: fallback)

        #expect(!following.paragraphs.isEmpty,
                "with a fallback locator the cursor must still find the next chapter")
        #expect(following.navigateTo != nil)
    }
}
