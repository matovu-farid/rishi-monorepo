@testable import rishi
import Testing
import Foundation




/// Smoke tests for the EPUB reader view layer. We deliberately do NOT
/// spin up a real `UIWindow` here — that requires the main runloop and
/// is XCUITest territory. The smoke tests verify:
///   1. VM publishes `publication` + `title` after `load()`.
///   2. On UIKit hosts, the coordinator can build the navigator from the
///      VM without throwing.
@Suite("ReaderView smoke", .serialized)
struct ReaderViewSmokeTests {

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
    }

    @Test("VM contract — publication is reachable after load")
    func vmPublicationReachable() async throws {
        let url = try aliceURL()
        let vm = ReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 0.05
        )
        await vm.load()
        #expect(vm.publication != nil)
        #expect(!vm.title.isEmpty)
    }

    #if canImport(UIKit)
    @Test("Coordinator builds navigator lazily after publication loads")
    @MainActor
    func coordinatorBuildsNavigator() async throws {
        let url = try aliceURL()
        let vm = ReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 0.05
        )
        await vm.load()
        let coordinator = ReaderNavigatorCoordinator(viewModel: vm)
        try coordinator.makeNavigatorIfNeeded()
        #expect(coordinator.navigator != nil)
    }

    @Test("Coordinator no-ops when publication not yet loaded")
    @MainActor
    func coordinatorDefersWhenPublicationMissing() async throws {
        let url = try aliceURL()
        let vm = ReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 0.05
        )
        // No load() — publication is nil.
        let coordinator = ReaderNavigatorCoordinator(viewModel: vm)
        try coordinator.makeNavigatorIfNeeded()
        #expect(coordinator.navigator == nil)
    }
    #endif
}
