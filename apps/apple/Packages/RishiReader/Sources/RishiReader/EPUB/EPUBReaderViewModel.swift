import Foundation
import Observation
import ReadiumShared
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
    private let loader: EPUBPublicationLoader
    private let debounceSeconds: Double
    private var pendingPositionTask: Task<Void, Never>?

    public init(
        book: Book,
        userId: UserID,
        documentURL: URL,
        positionStore: any PositionStore,
        loader: EPUBPublicationLoader = EPUBPublicationLoader(),
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
    public func load() async {
        do {
            let pub = try await loader.open(fileURL: documentURL)
            self.publication = pub
            self.title = pub.metadata.title ?? book.title

            // Restore last position.
            if let last = try? await positionStore.position(for: book.id),
               let wrapper = try? EPUBPositionLocator.decode(jsonString: last.locator),
               let restored = wrapper.toReadiumLocator() {
                self.latestLocator = restored
            }
        } catch {
            Log.reader.error("EPUBReaderViewModel.load failed for \(self.documentURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
