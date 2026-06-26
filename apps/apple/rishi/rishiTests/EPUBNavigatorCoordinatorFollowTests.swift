#if canImport(UIKit)
import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiReader

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
