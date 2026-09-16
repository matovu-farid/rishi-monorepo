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
    /// Exact locator last reported by Read Aloud. Manual navigation clears
    /// this candidate; programmatic page-follow does not.
    private var readAloudResumeLocator: Locator?
    private var latestPositionSource: ReaderPositionLocator.Source = .reader
    private var hasManualNavigationSinceLoad = false

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
    private var positionWriteTail: Task<Void, Never>?

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
        // The position lookup starts alongside publication opening so a
        // slow position store cannot add its full latency after parsing.
        // It is deliberately an unstructured child: if publication open
        // fails, we cancel the lookup without awaiting a store that may be
        // slow or non-cooperative. On success we still await the lookup
        // before publishing the one cohesive publication + locator state,
        // preserving the saved-page initial-location behavior.
        let bookId = book.id
        let positionStoreRef = positionStore
        let pub: Publication?
        let restoredPosition: (locator: Locator, source: ReaderPositionLocator.Source)?
        do {
            let result: (Publication, (locator: Locator, source: ReaderPositionLocator.Source)?) = try await Task.detached(priority: .userInitiated) { [loader, documentURL] in
                let positionTask = Task.detached(priority: .userInitiated) {
                    try? await positionStoreRef.position(for: bookId)
                }

                do {
                let publication = try await loader.open(fileURL: documentURL)
                let restored: (locator: Locator, source: ReaderPositionLocator.Source)?
                if let last = await positionTask.value {
                    if let wrapper = try? ReaderPositionLocator.decode(jsonString: last.locator),
                       let locator = wrapper.toReadiumLocator()
                    {
                        restored = (locator, wrapper.source)
                    } else if let locator = (try? EPUBPositionLocator.decode(jsonString: last.locator))?.toReadiumLocator() {
                        restored = (locator, .reader)
                    } else {
                        restored = nil
                    }
                } else {
                    restored = nil
                }
                return (publication, restored)
                } catch {
                    positionTask.cancel()
                    throw error
                }
            }.value
            pub = result.0
            restoredPosition = result.1
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
        if let restoredPosition {
            self.latestLocator = restoredPosition.locator
            self.latestPositionSource = restoredPosition.source
            if restoredPosition.source == .readAloud {
                self.readAloudResumeLocator = restoredPosition.locator
            }
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
    public func didChangeLocation(
        _ locator: Locator,
        isProgrammatic: Bool = false,
        isInitialLocation: Bool = false
    ) {
        let hasExactResume = readAloudResumeLocator != nil
        if !hasExactResume || (!isInitialLocation && !isProgrammatic) {
            latestLocator = locator
        }
        if !isProgrammatic && !isInitialLocation {
            readAloudResumeLocator = nil
            latestPositionSource = .reader
            hasManualNavigationSinceLoad = true
        }
        if !(isProgrammatic && readAloudResumeLocator != nil) {
            schedulePositionWrite(
                for: latestLocator ?? locator,
                source: latestPositionSource
            )
        }
        if !isProgrammatic && !isInitialLocation {
            onUserNavigation?(locator)
            onUserNavigationForTTSPagePrefetch?(locator)
        }
    }

    /// Records the exact locator currently narrated by Read Aloud without
    /// treating the playback update as user navigation. Read Aloud follows
    /// the reader's position persistence path, but must not feed the
    /// navigation callbacks that can stop playback or trigger prefetching.
    public func didChangeReadAloudLocation(_ locator: Locator) {
        readAloudResumeLocator = locator
        latestLocator = locator
        latestPositionSource = .readAloud
        schedulePositionWrite(for: locator, source: .readAloud)
    }

    /// Clears a narration candidate after a deliberate page change. This is
    /// separate from the navigator callback so a late Readium state callback
    /// cannot resurrect the old paragraph during navigation teardown.
    public func clearReadAloudResumeLocator() {
        readAloudResumeLocator = nil
        latestPositionSource = .reader
    }

    /// Returns the locator Read Aloud should use for a fresh synthesizer.
    /// Explicit selection always wins, followed by the exact saved narration
    /// position, followed by the live visible navigator position.
    @MainActor
    public func readAloudStartLocator(explicit: Locator? = nil) async -> Locator? {
        if let explicit { return explicit }
        if let readAloudResumeLocator { return readAloudResumeLocator }
        if hasManualNavigationSinceLoad, let latestLocator { return latestLocator }
        return await currentVisibleLocatorForReadAloud()
    }

    /// Flushes any pending debounced write immediately. Call on view dismiss.
    public func flush() async {
        while true {
            let pending = pendingPositionTask
            pending?.cancel()
            pendingPositionTask = nil
            await pending?.value
            // Debounced writes are serialized behind this tail. Awaiting the
            // tail drains writes that were already inside PositionStore when
            // cancellation happened; cancellation alone is not a barrier.
            await positionWriteTail?.value
            let locator = latestPositionSource == .readAloud
                ? (readAloudResumeLocator ?? latestLocator)
                : latestLocator
            if let locator {
                enqueuePositionWrite(for: locator, source: latestPositionSource)
                await positionWriteTail?.value
            }
            // A new locator may have arrived while the store write awaited;
            // loop once more to serialize and drain that newer write too.
            guard pendingPositionTask != nil else { return }
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

    private var isPDFPublication: Bool {
        book.formatType == .pdf || publication?.manifest.conforms(to: .pdf) == true
    }

    /// Build the live reading context handed to the voice session. Title +
    /// author always come from `book` so the model always knows the book.
    ///
    /// Reflowable EPUB leaves `currentPage` nil because it has no fixed integer
    /// page model. PDFs expose their current Readium page when available.
    /// `pageText` / `activeParagraphText` are left nil in the synchronous
    /// snapshot; surfacing visible text requires the async resource read in
    /// ``liveVoiceContext()``. The outline `chapters` + book identity already
    /// ground the model while that live context is being resolved.
    public func voiceContext() -> ReaderVoiceContext {
        ReaderVoiceContext(
            title: book.title,
            author: book.author,
            chapters: voiceChapters,
            currentPage: isPDFPublication ? latestLocator?.locations.page : nil,
            pageText: nil,
            activeParagraphText: nil
        )
    }

    @MainActor
    public func liveVoiceContext() async -> ReaderVoiceContext {
        let base = voiceContext()

        // The unified reader serves both EPUB and PDF publications. PDF
        // locators expose page text through Readium's PDF content sequence;
        // sending them through EPUBReadAloudCursor silently produces an empty
        // page context, which leaves the realtime model waiting on a useless
        // currentPageContext result even though the PDF contains selectable
        // text.
        if isPDFPublication,
           let publication,
           let locator = await currentVisibleLocatorForReadAloud() ?? latestLocator
        {
            let passages = await Self.pdfSentences(
                publication: publication,
                locator: locator
            )
            return ReaderVoiceContext(
                title: base.title,
                author: base.author,
                chapters: base.chapters,
                currentPage: locator.locations.page ?? base.currentPage,
                pageText: passages.isEmpty ? nil : passages.joined(separator: "\n\n"),
                activeParagraphText: base.activeParagraphText
            )
        }

        let paragraphs = await paragraphsForReadAloud()
        let text = paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
        return ReaderVoiceContext(
            title: base.title,
            author: base.author,
            chapters: base.chapters,
            currentPage: base.currentPage,
            pageText: text,
            activeParagraphText: base.activeParagraphText
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
    /// EPUB and PDF both use this API (unified reader). PDF content is read
    /// from Readium's publication content and tokenized into sentences;
    /// EPUB uses HTML paragraph chunking through ``EPUBReadAloudCursor``.
    @MainActor
    public func firstParagraphForPageEntryPrefetch(at locator: Locator) async -> String? {
        if book.formatType == .pdf
            || publication?.manifest.conforms(to: .pdf) == true
        {
            guard let publication else { return nil }
            return await Self.pdfSentences(
                publication: publication,
                locator: locator
            ).first
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
    /// - PDF: sentence-level passages from the same Readium content and
    ///   tokenizer path as playback.
    /// - EPUB: nearby window around progression start (`start-1...start+1`) so a
    ///   page-crossing swipe whose progression jumped one chunk ahead can still
    ///   match the spoken paragraph.
    @MainActor
    public func paragraphsForUserNavigationIntent(at locator: Locator) async -> [String] {
        if book.formatType == .pdf
            || publication?.manifest.conforms(to: .pdf) == true
        {
            guard let publication else { return [] }
            return await Self.pdfSentences(
                publication: publication,
                locator: locator
            )
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

    /// Returns the sentence passages exposed by Readium for a PDF locator.
    /// Keeping page-entry warmup and user-navigation matching on this path is
    /// important: it makes both consumers agree with the active speech
    /// synthesizer on utterance boundaries and locator text.
    nonisolated private static func pdfSentences(
        publication: Publication,
        locator: Locator
    ) async -> [String] {
        guard let content = publication.content(from: locator) else { return [] }

        let tokenizer = CustomTTSTokenizer.tokenize(
            defaultLanguage: publication.metadata.language,
            granularity: .sentence
        )
        var sentences: [String] = []
        let targetPage = locator.locations.page

        do {
            for await element in content.sequence() {
                guard !Task.isCancelled else { return sentences }
                if let targetPage,
                   let elementPage = element.locator.locations.page,
                   elementPage != targetPage
                {
                    // `content(from:)` continues through the resource. PDF
                    // navigation/page-entry helpers must stop at the current
                    // page so a later page cannot become a false match.
                    if !sentences.isEmpty { return sentences }
                    continue
                }
                for token in try tokenizer(element) {
                    switch token {
                    case let textElement as TextContentElement:
                        for segment in textElement.segments {
                            if let text = readablePDFText(segment.text) {
                                sentences.append(text)
                            }
                        }
                    case let textualElement as TextualContentElement:
                        if let text = readablePDFText(textualElement.text) {
                            sentences.append(text)
                        }
                    default:
                        continue
                    }
                }
            }
        } catch {
            return []
        }

        return sentences
    }

    private nonisolated static func readablePDFText(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        // Keep the exact tokenizer output. PublicationSpeechSynthesizer uses
        // this same segment text for the utterance and cache key; whitespace
        // normalization here would create avoidable cache misses.
        return text
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
        didChangeReadAloudLocation(locator)
    }

    // MARK: - Debounce

    private func schedulePositionWrite(
        for locator: Locator,
        source: ReaderPositionLocator.Source
    ) {
        pendingPositionTask?.cancel()
        let seconds = debounceSeconds
        // KEEP: VM is @Observable (not @MainActor); writePosition awaits
        // positionStore.upsert (actor). No main-bound work.
        pendingPositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            self?.enqueuePositionWrite(for: locator, source: source)
        }
    }

    private func enqueuePositionWrite(
        for locator: Locator,
        source: ReaderPositionLocator.Source
    ) {
        let previous = positionWriteTail
        positionWriteTail = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.writePosition(for: locator, source: source)
        }
    }

    private func writePosition(
        for locator: Locator,
        source: ReaderPositionLocator.Source
    ) async {
        let wrapper = ReaderPositionLocator(locator: locator, source: source)
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
