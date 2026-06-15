#if canImport(UIKit)
import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiReader

/// Deterministic guard for the read-aloud page-boundary halt (Bug 4).
///
/// When read-aloud auto-advances or the user presses Next across a Readium page
/// boundary, the coordinator programmatically turns the page
/// (`navigateToReadAloudParagraph`). An animated `go(to:)` delivers its
/// `locationDidChange` ~300ms AFTER it returns, and the read-aloud target
/// locator has no progression, so a single callback cannot be classified as
/// programmatic-vs-user. The old code reset a per-call flag synchronously after
/// `go(to:)`, so the delayed callback was read as a USER page-turn and fired
/// `onUserNavigation -> stopReadAloud`, halting playback at the boundary.
///
/// The fix is session-scoped: while a read-aloud session is following the text
/// (`isFollowingReadAloud == true`), every navigator location change is
/// auto-follow and must NOT fire `onUserNavigation`. These tests drive the
/// coordinator's location-change handling directly (no live `Navigator`
/// needed) and assert that invariant in both states.
@Suite("EPUB read-aloud page-boundary follow (Bug 4)", .serialized)
@MainActor
struct EPUBNavigatorCoordinatorFollowTests {

    /// Minimal store: the VM only needs something that conforms; these tests
    /// never read or persist a position.
    private struct NoopPositionStore: PositionStore {
        func position(for bookId: BookID) async throws -> Position? { nil }
        func upsert(_ position: Position) async throws {}
        func delete(_ id: PositionID) async throws {}
    }

    private final class Recorder { var locators: [Locator] = [] }

    private func makeViewModel() -> EPUBReaderViewModel {
        EPUBReaderViewModel(
            book: Book(
                userId: UUID(),
                title: "Alice",
                formatType: .epub,
                fileURL: "Books/x/alice.epub"
            ),
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: NoopPositionStore(),
            debounceSeconds: 5.0
        )
    }

    private func makeLocator(progression: Double) throws -> Locator {
        let href = try #require(RelativeURL(path: "OEBPS/chapter1.html"))
        return Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: progression, totalProgression: progression)
        )
    }

    @Test("While a session is following, a location change does NOT fire onUserNavigation (auto-follow must not stop playback)")
    func followingSuppressesUserNavigation() throws {
        let viewModel = makeViewModel()
        let coordinator = EPUBNavigatorCoordinator(viewModel: viewModel)
        let recorder = Recorder()
        viewModel.onUserNavigation = { recorder.locators.append($0) }

        coordinator.isFollowingReadAloud = true
        // The page-crossing callback that USED to halt read-aloud.
        coordinator.handleLocationChange(try makeLocator(progression: 0.66))

        #expect(recorder.locators.isEmpty)
    }

    @Test("With no following session, a location change fires onUserNavigation once (a real user page-turn)")
    func notFollowingForwardsUserNavigation() throws {
        let viewModel = makeViewModel()
        let coordinator = EPUBNavigatorCoordinator(viewModel: viewModel)
        let recorder = Recorder()
        viewModel.onUserNavigation = { recorder.locators.append($0) }

        coordinator.isFollowingReadAloud = false
        coordinator.handleLocationChange(try makeLocator(progression: 0.66))

        #expect(recorder.locators.count == 1)
    }

    @Test("Following suppresses EVERY crossing of a multi-page session, not just the first")
    func followingSuppressesAcrossMultipleBoundaries() throws {
        let viewModel = makeViewModel()
        let coordinator = EPUBNavigatorCoordinator(viewModel: viewModel)
        let recorder = Recorder()
        viewModel.onUserNavigation = { recorder.locators.append($0) }

        coordinator.isFollowingReadAloud = true
        for progression in [0.25, 0.5, 0.75, 1.0] {
            coordinator.handleLocationChange(try makeLocator(progression: progression))
        }

        #expect(recorder.locators.isEmpty)
    }
}
#endif
