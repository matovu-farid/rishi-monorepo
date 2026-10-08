import Foundation
import Observation
// Readium's installed APIs do not declare Publication Sendable. LoadResult
// confines the parse handoff; detached content helpers only read snapshots.
// This import does not establish general thread safety for Readium objects.
@preconcurrency import ReadiumShared



/// @Observable view-model for the EPUB reader. Mirrors the shape of
/// `PDFReaderViewModel` (Phase 5):
///   - `@Observable @MainActor final class` for isolated SwiftUI state
///   - `userId` is `internal` so the Wave-5 highlights extension can read it
///   - debounced position write (1s default) on locator change
///   - `flush()` drains the debounce on view dismiss
public enum ReaderPositionFlushResult: Sendable, Equatable {
    case committed, savedPublicationPending, writeFailed, revoked
}

@Observable
@MainActor
public final class ReaderViewModel {

    public let book: Book
    internal let userId: UserID

    /// Source URL of the EPUB on disk.
    public let documentURL: URL

    /// Optional owner for the immutable document source. The app layer passes
    /// its source lease here so playback owners that retain this view model
    /// also retain access after the reader screen disappears.
    let sourceLifetime: AnyObject?
    public let sourceAccessPermit: BookSourceAccessPermit?
    let sourceEffects: (any BookSourceEffectAdmitting)?
    private let sourceInvalidationSignal: BookSourceInvalidationSignal?
    var sourceInvalidation: AsyncStream<Void>? { sourceInvalidationSignal?.stream }

    /// Loaded publication; `nil` until `load()` completes.
    public private(set) var publication: Publication?

    /// Most recent locator emitted by the navigator delegate (or
    /// restored from the position store on load).
    public private(set) var latestLocator: Locator?
    /// Most recent position reported by the visible navigator. Narration can
    /// advance the resume cursor without moving the reader viewport.
    public private(set) var visibleNavigatorLocator: Locator?
    /// Exact locator last reported by Read Aloud. Manual navigation clears
    /// this candidate; programmatic page-follow does not.
    private var readAloudResumeLocator: Locator?
    public private(set) var latestPositionSource: ReaderPositionLocator.Source = .reader
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

    /// Carries a deliberate local PDF page-forward intent through Readium's
    /// asynchronous location callback without treating it as a generic swipe.
    public var onExplicitPageForwardNavigation: ((Locator, UUID) -> Void)?

    @ObservationIgnored private var navigationCallbackOwner: UUID?

    /// Installs one destination's complete callback group atomically.
    @MainActor
    public func installNavigationCallbacks(
        owner: UUID,
        onUserNavigation: @escaping (Locator) -> Void,
        onUserNavigationForTTSPagePrefetch: @escaping (Locator) -> Void,
        onExplicitPageForwardNavigation: @escaping (Locator, UUID) -> Void
    ) {
        navigationCallbackOwner = owner
        self.onUserNavigation = onUserNavigation
        self.onUserNavigationForTTSPagePrefetch = onUserNavigationForTTSPagePrefetch
        self.onExplicitPageForwardNavigation = onExplicitPageForwardNavigation
    }

    @MainActor
    public func clearNavigationCallbacks(ifOwner owner: UUID) {
        guard navigationCallbackOwner == owner else { return }
        navigationCallbackOwner = nil
        onUserNavigation = nil
        onUserNavigationForTTSPagePrefetch = nil
        onExplicitPageForwardNavigation = nil
    }

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
    private var flushTask: Task<ReaderPositionFlushResult, Never>?
    private var positionID = UUID()
    private var progressRevision: UInt64 = 0
    private var handledRevision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var queuedRevision: UInt64 = 0
    private struct ProgressSnapshot {
        let position: Position
        let revision: UInt64
        /// The subscriber present when movement created this revision, including none.
        let publicationOwner: UUID?
    }
    private var progressSnapshot: ProgressSnapshot?
    private var progressBaseline: ReaderPositionLocator?
    public private(set) var positionSaveError: String?
    private var lastFlushResult: ReaderPositionFlushResult = .committed
    public typealias PersistedPositionHandler = @MainActor (
        Position, @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> PositionCommitResult
    @ObservationIgnored private var persistedPositionOwner: UUID?
    @ObservationIgnored private var persistedPositionHandler: PersistedPositionHandler?

    @MainActor
    public func installPersistedPositionHandler(owner: UUID, handler: @escaping PersistedPositionHandler) {
        persistedPositionOwner = owner
        persistedPositionHandler = handler
    }

    @MainActor
    public func clearPersistedPositionHandler(ifOwner owner: UUID) {
        guard persistedPositionOwner == owner else { return }
        persistedPositionOwner = nil
        persistedPositionHandler = nil
    }

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
        sourceLifetime: AnyObject? = nil,
        sourceAccessPermit: BookSourceAccessPermit? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        sourceInvalidationSignal: BookSourceInvalidationSignal? = nil,
        loader: any PublicationLoading = PublicationLoader(),
        debounceSeconds: Double = 1.0
    ) {
        self.book = book
        self.userId = userId
        self.documentURL = documentURL
        self.sourceLifetime = sourceLifetime
        self.sourceAccessPermit = sourceAccessPermit
        self.sourceEffects = sourceEffects
        self.sourceInvalidationSignal = sourceInvalidationSignal
        self.positionStore = positionStore
        self.loader = loader
        self.debounceSeconds = debounceSeconds
    }

    /// Immutable handoff of the parsed publication and restored position.
    /// One MainActor awaiter consumes it; this does not make Readium's
    /// mutable object graph safe for arbitrary concurrent access.
    private struct LoadResult: @unchecked Sendable {
        let publication: Publication
        let restored: (position: Position, locator: Locator?, source: ReaderPositionLocator.Source)?
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
        let loadAdmission: SourceEffectAdmission?
        do {
            loadAdmission = try sourceAdmission()
        } catch {
            loadingState = .failed(reason: "The book source is no longer available")
            return
        }
        defer { loadAdmission?.release() }

        // Phase 21 Plan 21-03 — flip to .loading BEFORE the detached
        // parse so the cold-open overlay binds immediately. Lands on
        // the caller's executor (typically MainActor via SwiftUI's
        // `.task`) so SwiftUI sees the transition on the same tick the
        // overlay first renders.
        self.loadingState = .loading

        // DETACHED: Readium ZIP unpack + parse are multi-second on large
        // EPUBs; offload to `.userInitiated` so the body and the awaited
        // continuation both land off-main. The result is consumed by a
        // single awaiter (this Task), with LoadResult confining the parsed
        // publication and restored-position handoff to that boundary.
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
        let restoredPosition: (position: Position, locator: Locator?, source: ReaderPositionLocator.Source)?
        do {
            let loadTask = Task.detached(priority: .userInitiated) { [loader, documentURL] in
                let positionTask = Task.detached(priority: .userInitiated) {
                    try await positionStoreRef.position(for: bookId)
                }

                return try await withTaskCancellationHandler {
                do {
                let publication = try await loader.open(fileURL: documentURL)
                try Task.checkCancellation()
                let restored: (position: Position, locator: Locator?, source: ReaderPositionLocator.Source)?
                if let last = try await positionTask.value {
                    if let wrapper = try? ReaderPositionLocator.decode(jsonString: last.locator),
                       let locator = wrapper.toReadiumLocator()
                    {
                        restored = (last, locator, wrapper.source)
                    } else if let locator = (try? EPUBPositionLocator.decode(jsonString: last.locator))?.toReadiumLocator() {
                        restored = (last, locator, .reader)
                    } else {
                        restored = (last, nil, .reader)
                    }
                } else {
                    restored = nil
                }
                return LoadResult(publication: publication, restored: restored)
                } catch {
                    positionTask.cancel()
                    throw error
                }
                } onCancel: { @Sendable [positionTask] in
                    positionTask.cancel()
                }
            }
            let result = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: { @Sendable [loadTask] in
                loadTask.cancel()
            }
            try Task.checkCancellation()
            pub = result.publication
            restoredPosition = result.restored
        } catch {
            Log.reader.error("ReaderViewModel.load failed for \(self.documentURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.loadingState = .failed(reason: error.localizedDescription)
            return
        }

        guard let pub else {
            self.loadingState = .failed(reason: "Loader returned nil publication")
            return
        }
        let publishAdmission: SourceEffectAdmission?
        do {
            publishAdmission = try sourceAdmission()
        } catch {
            loadingState = .failed(reason: "The book source changed while it was opening")
            return
        }
        defer { publishAdmission?.release() }
        // Single MainActor write block — assign publication, title,
        // latestLocator, and the loaded state atomically on the
        // caller's isolation after the full off-main round-trip
        // returns. SwiftUI sees one cohesive transition.
        self.publication = pub
        self.readAloudCursor = EPUBReadAloudCursor(publication: pub)
        self.title = pub.metadata.title ?? book.title
        if let restoredPosition {
            positionID = restoredPosition.position.id
            if let locator = restoredPosition.locator {
                progressBaseline = ReaderPositionLocator(locator: locator, source: restoredPosition.source)
            }
            self.latestLocator = restoredPosition.locator
            self.latestPositionSource = restoredPosition.source
            if restoredPosition.source == .readAloud {
                self.readAloudResumeLocator = restoredPosition.locator
            }
        }
        self.loadingState = .loaded
    }

    private func sourceAdmission() throws -> SourceEffectAdmission? {
        switch (sourceEffects, sourceAccessPermit) {
        case (nil, nil): return nil
        case let (.some(effects), .some(permit)): return try effects.admit(permit)
        default: throw BookSourceAccessError.unknownSource
        }
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
        isInitialLocation: Bool = false,
        explicitForwardID: UUID? = nil
    ) {
        visibleNavigatorLocator = locator
        let hasExactResume = readAloudResumeLocator != nil
        if !hasExactResume || (!isInitialLocation && !isProgrammatic) {
            latestLocator = locator
        }
        if !isProgrammatic && !isInitialLocation {
            readAloudResumeLocator = nil
            latestPositionSource = .reader
            hasManualNavigationSinceLoad = true
        }
        // Navigator restoration, reflow and auto-follow are visible-state
        // updates. Only a reading/narration movement creates a durable revision.
        if !isInitialLocation && !isProgrammatic {
            recordProgress(for: locator, source: .reader)
        } else if progressBaseline == nil {
            progressBaseline = ReaderPositionLocator(locator: latestLocator ?? locator, source: latestPositionSource)
        }
        if !isProgrammatic && !isInitialLocation {
            if let explicitForwardID {
                onExplicitPageForwardNavigation?(locator, explicitForwardID)
            } else {
                onUserNavigation?(locator)
                onUserNavigationForTTSPagePrefetch?(locator)
            }
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
        recordProgress(for: locator, source: .readAloud)
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

    /// Drains genuine movement and its finite publication boundary. Overlapping
    /// lifecycle and dismissal requests share one drain.
    @MainActor
    @discardableResult
    public func flush() async -> ReaderPositionFlushResult {
        if let flushTask { return await flushTask.value }
        let task = Task { @MainActor [self] in await drainPositionWrites() }
        flushTask = task
        let result = await task.value
        flushTask = nil
        return result
    }

    @MainActor
    private func drainPositionWrites() async -> ReaderPositionFlushResult {
        while true {
            let pending = pendingPositionTask
            pendingPositionTask = nil
            pending?.cancel()
            await pending?.value
            await positionWriteTail?.value
            guard let snapshot = progressSnapshot,
                  handledRevision < snapshot.revision else { return lastFlushResult }
            let revision = snapshot.revision
            enqueuePositionWrite(snapshot)
            await positionWriteTail?.value
            // Failures remain retryable on the next explicit flush. Movement
            // arriving during the await is still drained in this invocation.
            if progressRevision == revision { return lastFlushResult }
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
                locator: locator,
                documentURL: documentURL,
                sourceLifetime: sourceLifetime,
                sourceEffects: sourceEffects,
                sourceAccessPermit: sourceAccessPermit
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
                locator: locator,
                documentURL: documentURL,
                sourceLifetime: sourceLifetime,
                sourceEffects: sourceEffects,
                sourceAccessPermit: sourceAccessPermit
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
                locator: locator,
                documentURL: documentURL,
                sourceLifetime: sourceLifetime,
                sourceEffects: sourceEffects,
                sourceAccessPermit: sourceAccessPermit
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
        locator: Locator,
        documentURL: URL,
        sourceLifetime: AnyObject?,
        sourceEffects: (any BookSourceEffectAdmitting)?,
        sourceAccessPermit: BookSourceAccessPermit?
    ) async -> [String] {
        // Readium accepts an unknown href here, but its content sequence keeps
        // retrying the failed PDF resource. Reject unavailable resources before
        // constructing that iterator so best-effort helpers can return promptly.
        guard publication.readingOrder.firstIndexWithHREF(locator.href) != nil else { return [] }
        guard let content = publication.content(from: locator) else { return [] }

        let tokenizer = CustomTTSTokenizer.tokenizePDF(
            defaultLanguage: publication.metadata.language,
            paragraphMap: PDFNarrationParagraphMap(
                documentURL: documentURL,
                sourceLifetime: sourceLifetime,
                sourceEffects: sourceEffects,
                sourceAccessPermit: sourceAccessPermit
            )
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

    // MARK: - Durable progress

    private func recordProgress(for locator: Locator, source: ReaderPositionLocator.Source) {
        let wrapper = ReaderPositionLocator(locator: locator, source: source)
        guard wrapper != progressBaseline else { return }
        do {
            let encoded = try wrapper.encodedJSONString()
            progressBaseline = wrapper
            progressRevision &+= 1
            let snapshot = ProgressSnapshot(
                position: Position(
                    id: positionID, bookId: book.id, locator: encoded,
                    percentComplete: locator.locations.totalProgression ?? 0,
                    updatedAt: Date()
                ),
                revision: progressRevision,
                publicationOwner: persistedPositionOwner
            )
            progressSnapshot = snapshot
            pendingPositionTask?.cancel()
            let seconds = debounceSeconds
            pendingPositionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.pendingPositionTask = nil
                self?.enqueuePositionWrite(snapshot)
            }
        } catch {
            positionSaveError = error.localizedDescription
            lastFlushResult = .writeFailed
        }
    }

    private func enqueuePositionWrite(_ snapshot: ProgressSnapshot) {
        guard snapshot.revision > handledRevision,
              queuedRevision != snapshot.revision else { return }
        let revision = snapshot.revision
        queuedRevision = revision
        let previous = positionWriteTail
        positionWriteTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.writePosition(snapshot.position, revision: revision, publicationOwner: snapshot.publicationOwner)
            if self.queuedRevision == revision { self.queuedRevision = 0 }
        }
    }

    @MainActor
    private func writePosition(_ position: Position, revision: UInt64, publicationOwner: UUID?) async {
        guard revision > handledRevision else { return }
        let persist: @MainActor @Sendable () async throws -> Void = { [self] in
            guard savedRevision < revision else { return }
            let admission = try sourceAdmission()
            defer { admission?.release() }
            try await positionStore.upsert(position)
            savedRevision = revision
            positionSaveError = nil
        }
        do {
            let result: PositionCommitResult
            if let publicationOwner,
               publicationOwner == persistedPositionOwner,
               let handler = persistedPositionHandler {
                result = try await handler(position, persist)
            } else {
                try await persist()
                result = .committed
            }
            handledRevision = revision
            lastFlushResult = result == .committed ? .committed : .savedPublicationPending
        } catch {
            if error is BookSourceAccessError || error is BookSourceOwnerError || error is BookScopedMutationError {
                lastFlushResult = .revoked
            } else {
                lastFlushResult = savedRevision >= revision ? .savedPublicationPending : .writeFailed
            }
            positionSaveError = error.localizedDescription
            Log.reader.error("Failed to commit reader position: \(error.localizedDescription, privacy: .public)")
        }
    }
}
