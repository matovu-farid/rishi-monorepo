import Foundation
import Observation
// `@preconcurrency` downgrades the Readium `Publication` non-Sendable
// error to a warning when crossing the `Task.detached(...).value`
// boundary in `load()`. The detached task is a single-producer
// single-consumer transfer and the value is only mutated through
// nonisolated Readium APIs after handoff (parse-then-display), so the
// downgrade is sound here. Tracked as the documented Readium 3.x
// Swift 6 concurrency gap — Phase 19 plan 19-09 (F-P0-08 EPUB slice).
@preconcurrency import ReadiumShared
import RishiCore
import RishiLogging
import PDFKit

/// @Observable view-model for the EPUB reader. Mirrors the shape of
/// `PDFReaderViewModel` (Phase 5):
///   - `@Observable final class` for SwiftUI auto-tracking
///   - `@unchecked Sendable` because Readium types we hold are not Sendable
///   - `userId` is `internal` so the Wave-5 highlights extension can read it
///   - debounced position write (1s default) on locator change
///   - `flush()` drains the debounce on view dismiss
@Observable
public final class ReaderViewModel: @unchecked Sendable {

    public let book: Book
    internal let userId: UserID

    /// Source URL of the EPUB on disk.
    public let documentURL: URL

    /// Loaded publication; `nil` until `load()` completes.
    public private(set) var publication: Publication?

    /// Most recent locator emitted by the navigator delegate (or
    /// restored from the position store on load).
    public private(set) var latestLocator: Locator?

    /// Title pulled from the publication once loaded.
    public private(set) var title: String = ""

    public var theme: ReaderTheme = .default
    public var typography: ReaderTypography = .default

    /// Phase 21 Plan 21-03 — observable cold-open loading state.
    /// `ReaderScreen` overlays a native SwiftUI `ProgressView`
    /// while this is `.loading`, surfaces an error view on `.failed`,
    /// and renders the page content normally on `.loaded`. Starts
    /// `.idle` until ``load()`` runs.
    public private(set) var loadingState: ReaderLoadingState = .idle

    // MARK: - Phase 18 Plan 18-02 — F-P1-01 SwiftUI native haptics

    /// Monotonically-increasing trigger value observed by the reader
    /// screen's `.sensoryFeedback(.impact(weight: .light), trigger:)`
    /// modifier. SwiftUI fires the haptic whenever this value changes;
    /// callers should invoke ``advancePage()`` on every committed page
    /// turn rather than mutating the field directly. EPUB has no
    /// integer page model — Readium owns real position — so this is a
    /// synthetic counter that exists purely to drive the trigger
    /// binding. `&+` overflow wrapping keeps long sessions safe.
    public private(set) var currentPageIndex: Int = 0

    /// Monotonically-increasing trigger value observed by the reader
    /// screen's `.sensoryFeedback(.warning, trigger:)` modifier.
    /// Incremented whenever the navigator reports a boundary hit
    /// (before-first or after-last). Same overflow-wrapping semantics
    /// as ``currentPageIndex``.
    public private(set) var lastBoundaryHitTick: Int = 0

    /// Bumps ``currentPageIndex`` by 1. SwiftUI's
    /// `.sensoryFeedback(_:trigger:)` observes the change and fires a
    /// light impact haptic on the reader screen.
    public func advancePage() {
        currentPageIndex &+= 1
    }

    /// Bumps ``lastBoundaryHitTick`` by 1. SwiftUI's
    /// `.sensoryFeedback(_:trigger:)` observes the change and fires a
    /// warning notification haptic on the reader screen.
    public func hitBoundary() {
        lastBoundaryHitTick &+= 1
    }

    /// Fired only for USER-initiated locator changes (manual page
    /// turns / chapter switches), never for programmatic auto-follow
    /// navigation. The app layer wires this to stop stale read-aloud
    /// (TTS) audio when the reader leaves the page being narrated.
    public var onUserNavigation: ((Locator) -> Void)?

    /// Fired only for USER-initiated locator changes so the app layer can
    /// prefetch the first paragraph on the newly visible page without
    /// coupling that optimization to playback lifecycle.
    public var onUserNavigationForTTSPagePrefetch: ((Locator) -> Void)?

    /// Supplies the navigator's live visible locator when a caller needs to
    /// start read-aloud immediately after a page turn. Readium may deliver
    /// `locationDidChange` asynchronously while a page animation is still
    /// settling, so `latestLocator` is not always current at button-tap time.
    @MainActor
    public var currentVisibleLocatorProvider: (@MainActor () async -> Locator?)?

    private let positionStore: any PositionStore
    private let loader: any PublicationLoading
    private let debounceSeconds: Double
    private var pendingPositionTask: Task<Void, Never>?

    /// Read-aloud resource/page parsing + chapter-continuation cursor. Created
    /// when the publication loads (the cursor holds the publication). `nil`
    /// before ``load()`` completes, which the facade methods treat as "no
    /// paragraphs". This separates the read-aloud narration concern from the
    /// VM's reading-position responsibility (plan 34-06).
    private var readAloudCursor: EPUBReadAloudCursor?

    public init(
        book: Book,
        userId: UserID,
        documentURL: URL,
        positionStore: any PositionStore,
        loader: any PublicationLoading = PublicationLoader(),
        debounceSeconds: Double = 1.0
    ) {
        self.book = book
        self.userId = userId
        self.documentURL = documentURL
        self.positionStore = positionStore
        self.loader = loader
        self.debounceSeconds = debounceSeconds
    }

    // MARK: - Lifecycle

    /// Loads the publication and restores the last known locator (if any).
    /// Call once when the view appears.
    ///
    /// Phase 19 plan 19-09 (F-P0-08 EPUB slice): the Readium
    /// `AssetRetriever` + `PublicationOpener` pipeline does a
    /// multi-second ZIP unpack + parse on large EPUBs. SwiftUI `.task`
    /// inherits the enclosing view's `@MainActor` isolation, so a bare
    /// `await loader.open(...)` would resume the continuation on main
    /// and (worst case) execute parts of the body on main too. We hop
    /// to a detached `.userInitiated` task so the body and the awaited
    /// continuation both land off-main. Only the state assignment
    /// (`publication`, `title`, `latestLocator`) happens after we
    /// re-enter the caller's isolation.
    ///
    /// Note on the navigator factory: `EPUBNavigatorViewController` is
    /// a UIKit class and is hard-`@MainActor` by Readium's contract.
    /// We do NOT (and cannot) construct it off-main. Per RESEARCH
    /// §F-P0-08 the navigator `init` itself is cheap; the multi-second
    /// work is the publication parse handled here. The navigator is
    /// constructed in `ReaderScreen` from this `publication` value
    /// after `load()` completes, on main, where Readium expects it.
    public func load() async {
        // Phase 21 Plan 21-03 — flip to .loading BEFORE the detached
        // parse so the cold-open overlay binds immediately. Lands on
        // the caller's executor (typically MainActor via SwiftUI's
        // `.task`) so SwiftUI sees the transition on the same tick the
        // overlay first renders.
        self.loadingState = .loading

        // DETACHED: Readium ZIP unpack + parse are multi-second on large
        // EPUBs; offload to `.userInitiated` so the body and the awaited
        // continuation both land off-main. The result is consumed by a
        // single awaiter (this Task), so the non-Sendable `Publication`
        // crosses the boundary via the detached-task `sending` result.
        //
        // Phase 21 audit fix: the position-restore await is hoisted
        // into the detached block alongside the publication open so the
        // full round-trip is off-main and only the final assignment
        // block runs on the caller's isolation (MainActor under
        // SwiftUI's `.task`). Previously `positionStore.position(for:)`
        // ran between the parse completion and the `.loaded` write,
        // which left a tiny but real MainActor-resumed window between
        // two off-main hops.
        let bookId = book.id
        let positionStoreRef = positionStore
        let pub: Publication?
        let restoredLocator: Locator?
        do {
            let result: (Publication, Locator?) = try await Task.detached(priority: .userInitiated) { [loader, documentURL] in
                let publication = try await loader.open(fileURL: documentURL)
                let restored: Locator?
                if let last = try? await positionStoreRef.position(for: bookId) {
                    restored = (try? ReaderPositionLocator.decode(jsonString: last.locator))?.toReadiumLocator()
                        ?? (try? EPUBPositionLocator.decode(jsonString: last.locator))?.toReadiumLocator()
                } else {
                    restored = nil
                }
                return (publication, restored)
            }.value
            pub = result.0
            restoredLocator = result.1
        } catch {
            Log.reader.error("ReaderViewModel.load failed for \(self.documentURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.loadingState = .failed(reason: error.localizedDescription)
            return
        }

        guard let pub else {
            self.loadingState = .failed(reason: "Loader returned nil publication")
            return
        }
        // Single MainActor write block — assign publication, title,
        // latestLocator, and the loaded state atomically on the
        // caller's isolation after the full off-main round-trip
        // returns. SwiftUI sees one cohesive transition.
        self.publication = pub
        self.readAloudCursor = EPUBReadAloudCursor(publication: pub)
        self.title = pub.metadata.title ?? book.title
        if let restoredLocator {
            self.latestLocator = restoredLocator
        }
        self.loadingState = .loaded
    }

    // MARK: - Locator updates

    /// Called by the EPUBNavigatorDelegate (Wave 4 wiring) on every
    /// page turn / chapter switch. Updates `latestLocator` immediately
    /// and debounces a write through `PositionStore`.
    ///
    /// `isProgrammatic` distinguishes a USER page-turn (default `false`)
    /// from the read-aloud auto-follow navigation the coordinator drives
    /// via `nav.go(to:)`. Position-write behavior is identical for both
    /// cases; only the user-navigation callbacks are suppressed for
    /// programmatic changes so the auto-follow does not feed back into
    /// playback lifecycle or page-entry prefetch.
    public func didChangeLocation(_ locator: Locator, isProgrammatic: Bool = false) {
        latestLocator = locator
        schedulePositionWrite(for: locator)
        if !isProgrammatic {
            onUserNavigation?(locator)
            onUserNavigationForTTSPagePrefetch?(locator)
        }
    }

    /// Flushes any pending debounced write immediately. Call on view dismiss.
    public func flush() async {
        pendingPositionTask?.cancel()
        pendingPositionTask = nil
        if let locator = latestLocator {
            await writePosition(for: locator)
        }
    }

    // MARK: - Voice context

    /// Flat chapter titles for the voice model's outline, derived from the
    /// already-parsed Readium manifest TOC. Cheap (in-memory `[Link]`); falls
    /// back to each entry's href when a TOC entry has no title. Empty before
    /// the publication finishes loading.
    public var voiceChapters: [String] {
        guard let toc = publication?.manifest.tableOfContents else { return [] }
        return toc.map { $0.title ?? $0.href }
    }

    /// Build the live reading context handed to the voice session. Title +
    /// author always come from `book` so the model always knows the book.
    ///
    /// `currentPage` is left nil — reflowable EPUB has no fixed integer page
    /// model. `pageText` / `activeParagraphText` are left nil in v1: surfacing
    /// the visible text requires the async resource read in
    /// ``paragraphsForReadAloud()``, which we do not block the synchronous
    /// toolbar action on. The outline `chapters` + book identity already
    /// ground the model.
    public func voiceContext() -> ReaderVoiceContext {
        ReaderVoiceContext(
            title: book.title,
            author: book.author,
            chapters: voiceChapters,
            currentPage: nil,
            pageText: nil,
            activeParagraphText: nil
        )
    }

    // MARK: - Read-aloud

    /// Returns the navigator's current visible locator, falling back to the
    /// last location callback when the navigator is not yet available.
    @MainActor
    public func currentVisibleLocatorForReadAloud() async -> Locator? {
        await currentVisibleLocatorProvider?() ?? latestLocator
    }

    /// Returns the first paragraph visible at the current page for best-effort
    /// page-entry TTS prefetch. The publication and locator are captured
    /// synchronously on the main actor before the detached extraction begins,
    /// so the background task never reads mutable view-model state.
    ///
    /// EPUB and PDF both use this API (unified reader). PDF locators carry a
    /// 1-based `locations.page` and are extracted via ``PDFReadAloudParagraphs``;
    /// EPUB uses HTML chunking through ``EPUBReadAloudCursor``.
    @MainActor
    public func firstParagraphForPageEntryPrefetch(at locator: Locator) async -> String? {
        if book.formatType == .pdf
            || publication?.manifest.conforms(to: .pdf) == true
        {
            let url = documentURL
            let page1Based = locator.locations.page
            return await Task.detached(priority: .userInitiated) {
                Self.firstPDFParagraph(documentURL: url, page1Based: page1Based)
            }.value
        }

        guard let publication else { return nil }
        let publicationSnapshot = publication
        let locatorSnapshot = locator

        return await Task.detached(priority: .userInitiated) {
            await EPUBReadAloudCursor.paragraphsAtCurrentPage(
                publication: publicationSnapshot,
                locator: locatorSnapshot
            ).first
        }.value
    }

    /// Destination paragraph candidates for Read Aloud user-navigation intent.
    ///
    /// - PDF: single first paragraph (or empty), same extract as prefetch.
    /// - EPUB: nearby window around progression start (`start-1...start+1`) so a
    ///   page-crossing swipe whose progression jumped one chunk ahead can still
    ///   match the spoken paragraph.
    @MainActor
    public func paragraphsForUserNavigationIntent(at locator: Locator) async -> [String] {
        if book.formatType == .pdf
            || publication?.manifest.conforms(to: .pdf) == true
        {
            if let first = await firstParagraphForPageEntryPrefetch(at: locator) {
                return [first]
            }
            return []
        }

        guard let publication else { return [] }
        let publicationSnapshot = publication
        let locatorSnapshot = locator

        return await Task.detached(priority: .userInitiated) {
            await EPUBReadAloudCursor.nearbyParagraphsForUserNavigationIntent(
                publication: publicationSnapshot,
                locator: locatorSnapshot
            )
        }.value
    }

    /// 1-based Readium PDF page → first layout-aware paragraph on that page.
    nonisolated private static func firstPDFParagraph(
        documentURL: URL,
        page1Based: Int?
    ) -> String? {
        guard let page1Based, page1Based > 0,
              let document = PDFDocument(url: documentURL),
              let page = document.page(at: page1Based - 1)
        else {
            return nil
        }
        return PDFReadAloudParagraphs.paragraphs(from: page).first
    }

    /// Paragraphs for read-aloud, starting at the CURRENT page rather than the
    /// resource start. Reads the resource the current locator points to, chunks
    /// it via `ParagraphChunker.chunk(_:)`, and drops the paragraphs that
    /// precede the locator's within-resource progression so "Play" on a
    /// forwarded page begins at the paragraph the reader is looking at — not
    /// paragraph 0 of the resource (the page-1 bug). Returns `[]` on failure.
    ///
    /// The returned array is a SLICE from the page's first paragraph onward;
    /// the read-aloud bridge indexes into it from 0, so the highlight index and
    /// the spoken paragraph stay aligned with what is on screen.
    public func paragraphsForReadAloud() async -> [String] {
        guard let readAloudCursor, let locator = latestLocator else { return [] }
        let result = await readAloudCursor.paragraphsAtCurrentPage(locator: locator)
        applyReadAloudNavigation(result.navigateTo)
        return result.paragraphs
    }

    /// Paragraphs for the NEXT reading-order resource (chapter) after the one
    /// read-aloud is currently narrating, so playback continues across a chapter
    /// boundary instead of halting at the last paragraph of the current chapter.
    ///
    /// Advances the read-aloud chapter cursor past any intervening resources
    /// that chunk to zero paragraphs (covers, blank section breaks) and returns
    /// the first non-empty chapter's full paragraph list. Returns `[]` at the
    /// end of the book (no further non-empty resource), which the bridge treats
    /// as "stop". The cursor falls back to ``latestLocator`` the first time if
    /// ``paragraphsForReadAloud()`` has not yet run.
    public func paragraphsForFollowingResource() async -> [String] {
        guard let readAloudCursor else { return [] }
        let result = await readAloudCursor.paragraphsFollowing(fallbackLocator: latestLocator)
        applyReadAloudNavigation(result.navigateTo)
        return result.paragraphs
    }

    /// Paragraphs for the PREVIOUS reading-order resource (chapter) before the
    /// one read-aloud is currently narrating, so pressing Previous on the first
    /// paragraph of a chapter continues backward across the chapter boundary
    /// instead of being a no-op. The backward mirror of
    /// ``paragraphsForFollowingResource()``: it steps the read-aloud chapter
    /// cursor back past any intervening resources that chunk to zero paragraphs
    /// (covers, blank section breaks) and returns the first non-empty chapter's
    /// full paragraph list. Returns `[]` at the start of the book (no earlier
    /// non-empty resource), which the bridge treats as "stay put".
    public func paragraphsForPrecedingResource() async -> [String] {
        guard let readAloudCursor else { return [] }
        let result = await readAloudCursor.paragraphsPreceding(fallbackLocator: latestLocator)
        applyReadAloudNavigation(result.navigateTo)
        return result.paragraphs
    }

    /// Applies the cursor's explicit "navigate to this chapter" intent to
    /// ``latestLocator`` so the text-anchored read-aloud follow turns the page
    /// into the new chapter. No-op when the batch did not cross a resource
    /// boundary. The locator mutation is now an explicit hand-off from the
    /// cursor rather than a hidden side effect of paragraph fetching.
    private func applyReadAloudNavigation(_ locator: Locator?) {
        guard let locator else { return }
        latestLocator = locator
    }

    // MARK: - Debounce

    private func schedulePositionWrite(for locator: Locator) {
        pendingPositionTask?.cancel()
        let seconds = debounceSeconds
        // KEEP: VM is @Observable (not @MainActor); writePosition awaits
        // positionStore.upsert (actor). No main-bound work.
        pendingPositionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            await self?.writePosition(for: locator)
        }
    }

    private func writePosition(for locator: Locator) async {
        let wrapper = ReaderPositionLocator(locator: locator)
        let encoded: String
        do {
            encoded = try wrapper.encodedJSONString()
        } catch {
            Log.reader.error("Failed to encode EPUB position locator: \(error.localizedDescription, privacy: .public)")
            return
        }
        let position = Position(
            bookId: book.id,
            locator: encoded,
            percentComplete: locator.locations.totalProgression ?? 0,
            updatedAt: Date()
        )
        do {
            try await positionStore.upsert(position)
        } catch {
            Log.reader.error("Failed to persist EPUB position: \(error.localizedDescription, privacy: .public)")
        }
    }
}
