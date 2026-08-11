@testable import rishi
#if canImport(UIKit)
import Testing
import Foundation
import ReadiumShared



@Suite("EPUB read-aloud page-boundary follow (Bug 4)", .serialized)
@MainActor
struct ReaderNavigatorCoordinatorFollowTests {

    /// Minimal store: the VM only needs something that conforms; these tests
    /// never read or persist a position.
    private struct NoopPositionStore: PositionStore {
        func position(for bookId: BookID) async throws -> Position? { nil }
        func upsert(_ position: Position) async throws {}
        func delete(_ id: PositionID) async throws {}
    }

    private final class Recorder { var locators: [Locator] = [] }

    private func makeViewModel() -> ReaderViewModel {
        ReaderViewModel(
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

    @Test("A user page turn while read-aloud is following stops navigation-owned playback")
    func userPageTurnDuringFollowingForwardsNavigation() throws {
        let viewModel = makeViewModel()
        let coordinator = ReaderNavigatorCoordinator(viewModel: viewModel)
        let recorder = Recorder()
        viewModel.onUserNavigation = { recorder.locators.append($0) }

        coordinator.isFollowingReadAloud = true
        coordinator.handleLocationChange(try makeLocator(progression: 0.66))

        #expect(recorder.locators.count == 1)
    }

    @Test("A registered Readium auto-follow location does not stop playback")
    func registeredProgrammaticLocationIsSuppressed() throws {
        let viewModel = makeViewModel()
        let coordinator = ReaderNavigatorCoordinator(viewModel: viewModel)
        let recorder = Recorder()
        viewModel.onUserNavigation = { recorder.locators.append($0) }

        let locator = try makeLocator(progression: 0.66)
        coordinator.registerProgrammaticNavigation()
        coordinator.handleLocationChange(locator)

        #expect(recorder.locators.isEmpty)
    }

    @Test("Only the matching auto-follow callback is suppressed")
    func unrelatedLocationStillForwardsNavigation() throws {
        let viewModel = makeViewModel()
        let coordinator = ReaderNavigatorCoordinator(viewModel: viewModel)
        let recorder = Recorder()
        viewModel.onUserNavigation = { recorder.locators.append($0) }

        coordinator.isFollowingReadAloud = true
        let autoFollow = try makeLocator(progression: 0.5)
        coordinator.registerProgrammaticNavigation()
        coordinator.handleLocationChange(autoFollow)
        coordinator.handleLocationChange(try makeLocator(progression: 0.75))

        #expect(recorder.locators.count == 1)
    }

    @Test("Committed location changes notify the reader chrome")
    func committedLocationChangesNotifyReaderChrome() throws {
        let viewModel = makeViewModel()
        let coordinator = ReaderNavigatorCoordinator(viewModel: viewModel)
        var events: [String] = []
        coordinator.onPageLocationChange = { events.append("chrome") }
        viewModel.onUserNavigation = { _ in events.append("tts") }

        // Readium's first location establishes the initial reader position;
        // it must not replace the toolbar's longer initial timer.
        coordinator.handleLocationChange(try makeLocator(progression: 0.50))
        #expect(events == ["tts"])

        coordinator.handleLocationChange(try makeLocator(progression: 0.66))
        #expect(events == ["tts", "chrome", "tts"])

        coordinator.registerProgrammaticNavigation()
        coordinator.handleLocationChange(try makeLocator(progression: 0.75))
        #expect(events == ["tts", "chrome", "tts"])
    }
}
#endif
