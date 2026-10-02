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

    private func makeViewModel(formatType: BookFormat = .epub) -> ReaderViewModel {
        ReaderViewModel(
            book: Book(
                userId: UUID(),
                title: "Alice",
                formatType: formatType,
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
        #expect(events.isEmpty)

        coordinator.handleLocationChange(try makeLocator(progression: 0.66))
        #expect(events == ["chrome", "tts"])

        coordinator.registerProgrammaticNavigation()
        coordinator.handleLocationChange(try makeLocator(progression: 0.75))
        #expect(events == ["chrome", "tts"])
    }

    @Test("PDF follow compares the target with the visible page")
    func pdfFollowUsesVisiblePage() {
        #expect(ReaderNavigatorCoordinator.shouldFollowPDFTarget(targetPage: 2, visiblePage: 1))
        #expect(!ReaderNavigatorCoordinator.shouldFollowPDFTarget(targetPage: 2, visiblePage: 2))
        #expect(ReaderNavigatorCoordinator.shouldFollowPDFTarget(targetPage: 2, visiblePage: nil))
    }

    @Test("PDF follow processes the newest page target after an earlier go-to returns")
    func pdfFollowProcessesPendingTarget() async throws {
        let viewModel = makeViewModel(formatType: .pdf)
        let coordinator = ReaderNavigatorCoordinator(viewModel: viewModel)
        let harness = FollowNavigationHarness()
        coordinator.isFollowingReadAloud = true
        coordinator.readAloudFollowNavigationForTesting = { locator in
            await harness.navigate(to: locator.locations.page ?? -1)
            viewModel.didChangeLocation(locator, isProgrammatic: true)
            return true
        }

        let page1 = try makePDFLocator(page: 1)
        let page2 = try makePDFLocator(page: 2)
        let page3 = try makePDFLocator(page: 3)
        viewModel.didChangeLocation(page1, isInitialLocation: true)
        viewModel.didChangeReadAloudLocation(page2)
        coordinator.followReadAloudLocator(page2)
        await harness.waitForPage2()

        coordinator.followReadAloudLocator(page3)
        await harness.releasePage2()
        await harness.waitForPage3()

        #expect(await harness.pagesSnapshot() == [2, 3])
        #expect(viewModel.visibleNavigatorLocator?.locations.page == 3)
    }

    private func makePDFLocator(page: Int) throws -> Locator {
        let href = try #require(RelativeURL(path: "document.pdf"))
        return Locator(
            href: href,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=\(page)"], position: page)
        )
    }
}

private actor FollowNavigationHarness {
    private(set) var pages: [Int] = []
    private var page2Continuation: CheckedContinuation<Void, Never>?
    private var page2Waiter: CheckedContinuation<Void, Never>?
    private var page3Waiter: CheckedContinuation<Void, Never>?

    func navigate(to page: Int) async {
        pages.append(page)
        if page == 2 {
            page2Waiter?.resume()
            page2Waiter = nil
            await withCheckedContinuation { page2Continuation = $0 }
        } else if page == 3 {
            page3Waiter?.resume()
            page3Waiter = nil
        }
    }

    func waitForPage2() async {
        guard !pages.contains(2) else { return }
        await withCheckedContinuation { page2Waiter = $0 }
    }

    func releasePage2() {
        page2Continuation?.resume()
        page2Continuation = nil
    }

    func waitForPage3() async {
        guard !pages.contains(3) else { return }
        await withCheckedContinuation { page3Waiter = $0 }
    }

    func pagesSnapshot() -> [Int] { pages }
}
#endif
