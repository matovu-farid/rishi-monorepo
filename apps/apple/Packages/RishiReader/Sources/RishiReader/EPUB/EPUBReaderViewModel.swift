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

    private let positionStore: any PositionStore
    private let loader: any EPUBPublicationLoading
    private let debounceSeconds: Double
    private var pendingPositionTask: Task<Void, Never>?

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
        // DETACHED: Readium ZIP unpack + parse are multi-second on large
        // EPUBs; offload to `.userInitiated` so the body and the awaited
        // continuation both land off-main. The result is consumed by a
        // single awaiter (this Task), so the non-Sendable `Publication`
        // crosses the boundary via the detached-task `sending` result.
        let pub: Publication?
        do {
            pub = try await Task.detached(priority: .userInitiated) { [loader, documentURL] in
                try await loader.open(fileURL: documentURL)
            }.value
        } catch {
            Log.reader.error("EPUBReaderViewModel.load failed for \(self.documentURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let pub else { return }
        self.publication = pub
        self.title = pub.metadata.title ?? book.title

        // Restore last position.
        if let last = try? await positionStore.position(for: book.id),
           let wrapper = try? EPUBPositionLocator.decode(jsonString: last.locator),
           let restored = wrapper.toReadiumLocator() {
            self.latestLocator = restored
        }
    }

    // MARK: - Locator updates

    /// Called by the EPUBNavigatorDelegate (Wave 4 wiring) on every
    /// page turn / chapter switch. Updates `latestLocator` immediately
    /// and debounces a write through `PositionStore`.
    public func didChangeLocation(_ locator: Locator) {
        latestLocator = locator
        schedulePositionWrite(for: locator)
    }

    /// Flushes any pending debounced write immediately. Call on view dismiss.
    public func flush() async {
        pendingPositionTask?.cancel()
        pendingPositionTask = nil
        if let locator = latestLocator {
            await writePosition(for: locator)
        }
    }

    // MARK: - Debounce

    private func schedulePositionWrite(for locator: Locator) {
        pendingPositionTask?.cancel()
        let seconds = debounceSeconds
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
