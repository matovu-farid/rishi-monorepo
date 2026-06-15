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

/// @Observable view-model for the EPUB reader. Mirrors the shape of
/// `PDFReaderViewModel` (Phase 5):
///   - `@Observable final class` for SwiftUI auto-tracking
///   - `@unchecked Sendable` because Readium types we hold are not Sendable
///   - `userId` is `internal` so the Wave-5 highlights extension can read it
///   - debounced position write (1s default) on locator change
///   - `flush()` drains the debounce on view dismiss
@Observable
public final class EPUBReaderViewModel: @unchecked Sendable {

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
    /// `EPUBReaderScreen` overlays a native SwiftUI `ProgressView`
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

    private let positionStore: any PositionStore
    private let loader: any EPUBPublicationLoading
    private let debounceSeconds: Double
    private var pendingPositionTask: Task<Void, Never>?

    /// Reading-order resource (chapter) that read-aloud is currently narrating.
    /// Set by ``paragraphsForReadAloud()`` and advanced by
    /// ``paragraphsForFollowingResource()`` so chapter continuation does not
    /// depend on the navigator's (asynchronous) locator updates. Fragment is
    /// stripped so it matches a reading-order ``Link`` href.
    private var readAloudResourceHref: AnyURL?

    public init(
        book: Book,
        userId: UserID,
        documentURL: URL,
        positionStore: any PositionStore,
        loader: any EPUBPublicationLoading = EPUBPublicationLoader(),
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
    /// constructed in `EPUBReaderScreen` from this `publication` value
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
                if let last = try? await positionStoreRef.position(for: bookId),
                   let wrapper = try? EPUBPositionLocator.decode(jsonString: last.locator) {
                    restored = wrapper.toReadiumLocator()
                } else {
                    restored = nil
                }
                return (publication, restored)
            }.value
            pub = result.0
            restoredLocator = result.1
        } catch {
            Log.reader.error("EPUBReaderViewModel.load failed for \(self.documentURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
    /// cases; only ``onUserNavigation`` is suppressed for programmatic
    /// changes so the auto-follow does not feed back and kill the audio
    /// it is following.
    public func didChangeLocation(_ locator: Locator, isProgrammatic: Bool = false) {
        latestLocator = locator
        schedulePositionWrite(for: locator)
        if !isProgrammatic {
            onUserNavigation?(locator)
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

    // MARK: - Read-aloud

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
        guard let publication = publication,
              let locator = latestLocator else { return [] }
        guard let resource = publication.get(locator.href) else { return [] }
        // Anchor the read-aloud chapter cursor on the resource we are about to
        // narrate so ``paragraphsForFollowingResource()`` can advance from here.
        readAloudResourceHref = locator.href.removingFragment()
        let result = await resource.read().asString(encoding: .utf8)
        guard case .success(let html) = result else { return [] }
        let all = ParagraphChunker.chunk(html)
        let start = ParagraphChunker.startIndex(
            forProgression: locator.locations.progression,
            count: all.count
        )
        guard start < all.count else { return [] }
        return Array(all[start...])
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
        guard let publication = publication else { return [] }
        // Cursor first (set as each chapter starts narrating); fall back to the
        // live locator before the first chapter's paragraphs were requested.
        guard let currentHref = readAloudResourceHref ?? latestLocator?.href.removingFragment()
        else { return [] }
        let order = publication.readingOrder
        guard let currentIndex = order.firstIndexWithHREF(currentHref) else { return [] }

        var nextIndex = currentIndex + 1
        while nextIndex < order.count {
            let link = order[nextIndex]
            if let resource = publication.get(link),
               case .success(let html) = await resource.read().asString(encoding: .utf8) {
                let paragraphs = ParagraphChunker.chunk(html)
                if !paragraphs.isEmpty {
                    readAloudResourceHref = link.url().removingFragment()
                    // Move the live locator to the new chapter so the
                    // text-anchored read-aloud follow (which anchors to
                    // `latestLocator.href`) turns the page into this resource
                    // rather than failing to find the paragraph in the old one.
                    if let locator = await publication.locate(link) {
                        latestLocator = locator
                    }
                    return paragraphs
                }
            }
            nextIndex += 1
        }
        return []
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
        let wrapper = EPUBPositionLocator(locator: locator)
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
