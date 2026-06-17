import Foundation
// `@preconcurrency` downgrades the Readium `Publication` non-Sendable
// error to a warning, matching ``EPUBReaderViewModel`` which hands this
// cursor the same already-parsed publication value.
@preconcurrency import ReadiumShared
import RishiCore

/// Read-aloud resource/page parsing + chapter-continuation cursor for the
/// EPUB reader.
///
/// Extracted from ``EPUBReaderViewModel`` (plan 34-06): the VM is responsible
/// for reading **position** (locator debounce/persist), while this collaborator
/// owns the orthogonal read-aloud responsibility — reading the Readium resource
/// the reader is on, chunking its HTML via `ParagraphChunker`, and walking the
/// reading order forward/backward across chapter boundaries. It holds the
/// `readAloudResourceHref` narration cursor (unrelated to position persistence)
/// so chapter continuation does not depend on the navigator's asynchronous
/// locator updates.
///
/// **Explicit locator intent.** Where the old in-VM methods mutated the VM's
/// `latestLocator` as a hidden side effect of fetching paragraphs, this cursor
/// instead returns a ``Result`` carrying the paragraphs plus an optional
/// `navigateTo` locator the VM applies explicitly. The position mutation is now
/// a visible contract between the two types rather than a buried coupling.
///
/// `@unchecked Sendable` mirrors ``EPUBReaderViewModel`` — the Readium
/// `Publication` it holds is not Sendable, but it is only mutated through the
/// nonisolated Readium APIs after the parse handoff.
final class EPUBReadAloudCursor: @unchecked Sendable {

    /// Paragraphs for a read-aloud batch plus the locator (if any) the reader
    /// should navigate to so the visible page follows the narrated chapter.
    struct Result {
        let paragraphs: [String]
        /// Locator the VM should adopt as its `latestLocator` so the
        /// text-anchored read-aloud follow turns the page into the new chapter.
        /// `nil` when the batch does not cross a resource boundary.
        let navigateTo: Locator?

        static let empty = Result(paragraphs: [], navigateTo: nil)
    }

    private let publication: Publication

    /// Reading-order resource (chapter) that read-aloud is currently narrating.
    /// Set by ``paragraphsAtCurrentPage(locator:)`` and advanced by the
    /// following/preceding walks so chapter continuation does not depend on the
    /// navigator's (asynchronous) locator updates. Fragment is stripped so it
    /// matches a reading-order ``Link`` href.
    private var readAloudResourceHref: AnyURL?

    init(publication: Publication) {
        self.publication = publication
    }

    /// Paragraphs for read-aloud starting at the CURRENT page rather than the
    /// resource start. Reads the resource the locator points to, chunks it via
    /// `ParagraphChunker.chunk(_:)`, and drops the paragraphs that precede the
    /// locator's within-resource progression so "Play" on a forwarded page
    /// begins at the paragraph the reader is looking at — not paragraph 0 of the
    /// resource (the page-1 bug). Returns `[]` on failure. Does not request a
    /// navigation (the reader is already on this page).
    func paragraphsAtCurrentPage(locator: Locator) async -> Result {
        guard let resource = publication.get(locator.href) else { return .empty }
        // Anchor the read-aloud chapter cursor on the resource we are about to
        // narrate so ``paragraphsFollowing`` can advance from here.
        readAloudResourceHref = locator.href.removingFragment()
        let result = await resource.read().asString(encoding: .utf8)
        guard case .success(let html) = result else { return .empty }
        let all = ParagraphChunker.chunk(html)
        let start = ParagraphChunker.startIndex(
            forProgression: locator.locations.progression,
            count: all.count
        )
        guard start < all.count else { return .empty }
        return Result(paragraphs: Array(all[start...]), navigateTo: nil)
    }

    /// Paragraphs for the NEXT reading-order resource (chapter) after the one
    /// read-aloud is currently narrating, so playback continues across a chapter
    /// boundary instead of halting at the last paragraph of the current chapter.
    ///
    /// Advances the read-aloud chapter cursor past any intervening resources
    /// that chunk to zero paragraphs (covers, blank section breaks) and returns
    /// the first non-empty chapter's full paragraph list. Returns `.empty` at the
    /// end of the book (no further non-empty resource), which the bridge treats
    /// as "stop". The cursor falls back to `fallbackLocator` the first time if
    /// ``paragraphsAtCurrentPage(locator:)`` has not yet run.
    func paragraphsFollowing(fallbackLocator: Locator?) async -> Result {
        await paragraphsCrossingBoundary(fallbackLocator: fallbackLocator, step: 1)
    }

    /// Paragraphs for the PREVIOUS reading-order resource (chapter) before the
    /// one read-aloud is currently narrating, so pressing Previous on the first
    /// paragraph of a chapter continues backward across the chapter boundary
    /// instead of being a no-op. The backward mirror of ``paragraphsFollowing``:
    /// steps the read-aloud chapter cursor back past any intervening resources
    /// that chunk to zero paragraphs and returns the first non-empty chapter's
    /// full paragraph list. Returns `.empty` at the start of the book, which the
    /// bridge treats as "stay put".
    func paragraphsPreceding(fallbackLocator: Locator?) async -> Result {
        await paragraphsCrossingBoundary(fallbackLocator: fallbackLocator, step: -1)
    }

    /// Shared forward/backward reading-order walk. `step` is `+1` (following) or
    /// `-1` (preceding). Preserves the original per-direction behavior verbatim:
    /// skip empty resources, anchor the cursor on the first non-empty one, and
    /// emit a navigate intent into it.
    private func paragraphsCrossingBoundary(fallbackLocator: Locator?, step: Int) async -> Result {
        // Cursor first (set as each chapter starts narrating); fall back to the
        // live locator before the first chapter's paragraphs were requested.
        guard let currentHref = readAloudResourceHref ?? fallbackLocator?.href.removingFragment()
        else { return .empty }
        let order = publication.readingOrder
        guard let currentIndex = order.firstIndexWithHREF(currentHref) else { return .empty }

        var index = currentIndex + step
        while index >= 0 && index < order.count {
            let link = order[index]
            if let resource = publication.get(link),
               case .success(let html) = await resource.read().asString(encoding: .utf8) {
                let paragraphs = ParagraphChunker.chunk(html)
                if !paragraphs.isEmpty {
                    readAloudResourceHref = link.url().removingFragment()
                    // Move the live locator to the new chapter so the
                    // text-anchored read-aloud follow (which anchors to
                    // `latestLocator.href`) turns the page into this resource
                    // rather than failing to find the paragraph in the old one.
                    let navigateTo = await publication.locate(link)
                    return Result(paragraphs: paragraphs, navigateTo: navigateTo)
                }
            }
            index += step
        }
        return .empty
    }
}
