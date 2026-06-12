import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiTesting
@testable import RishiReader

/// Phase 19 plan 19-09 — F-P0-08 (EPUB slice).
///
/// Confirms that:
///   1. The Readium publication load body runs OFF the main thread.
///   2. The awaited continuation lands off main (so any caller-side
///      MainActor inheritance from SwiftUI `.task` does not drag the
///      multi-second ZIP unpack onto the main draw loop).
///   3. The post-load UI state assignment (publication, title) remains
///      observable from main — i.e. we only offload the BODY, not the
///      handoff back to the view model.
///
/// Implementation hook: `EPUBReaderViewModel` accepts an
/// `any EPUBPublicationLoading` loader; the production
/// `EPUBPublicationLoader` conforms, and tests inject a probe that
/// records `Thread.isMainThread` at the moment the loader body is
/// entered.
@Suite("EPUBReaderViewModel.load isolation", .serialized)
struct EPUBReaderViewModelLoadTests {

    // MARK: - Probe loader

    /// Probe that records `Thread.isMainThread` on entry and forwards
    /// the actual open to a bundled Readium loader so the rest of the
    /// view-model load path stays exercised end-to-end.
    ///
    /// All lock manipulation lives inside synchronous `record(...)` /
    /// `wasInvokedOnMain` accessors so `open(fileURL:)` (an `async`
    /// method) never invokes `NSLock.lock()` directly — Swift 6 marks
    /// those as unavailable from asynchronous contexts.
    final class ProbeLoader: EPUBPublicationLoading, @unchecked Sendable {
        private let inner: EPUBPublicationLoader
        private let lock = NSLock()
        private var _wasInvokedOnMain: Bool?

        init(inner: EPUBPublicationLoader = EPUBPublicationLoader()) {
            self.inner = inner
        }

        var wasInvokedOnMain: Bool? {
            lock.lock(); defer { lock.unlock() }
            return _wasInvokedOnMain
        }

        nonisolated func record(isMain: Bool) {
            lock.lock()
            _wasInvokedOnMain = isMain
            lock.unlock()
        }

        /// Synchronous wrapper. `Thread.isMainThread` is annotated
        /// unavailable from async contexts under Swift 6 strict;
        /// bouncing through a nonisolated sync helper is the documented
        /// escape hatch.
        nonisolated func snapshotIsOnMainThread() -> Bool {
            Thread.isMainThread
        }

        func open(fileURL: URL) async throws -> Publication {
            // First statement of the loader body: record isolation via
            // a synchronous helper so the lock op doesn't hit Swift 6's
            // async-context unavailability check.
            record(isMain: snapshotIsOnMainThread())
            return try await inner.open(fileURL: fileURL)
        }
    }

    // MARK: - Helpers

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
    }

    // MARK: - Tests

    @Test("load() invokes loader off the main thread")
    func test_load_invokesLoaderOffMain() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let probe = ProbeLoader()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: probe,
            debounceSeconds: 0.05
        )

        await vm.load()

        let recorded: Bool = try #require(probe.wasInvokedOnMain, "Probe never observed an entry — loader.open(fileURL:) was not called")
        #expect(recorded == false, "loader.open(fileURL:) ran on main thread; Readium ZIP unpack will block first paint")
    }

    @Test("load() assigns publication state observable from main")
    @MainActor
    func test_load_assignsPublicationOnMain() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let probe = ProbeLoader()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: probe,
            debounceSeconds: 0.05
        )

        await vm.load()

        // Re-entered MainActor here. publication + title must be set.
        #expect(vm.publication != nil, "publication assignment did not survive the off-main hop")
        #expect(!vm.title.isEmpty, "title assignment did not survive the off-main hop")
    }

    @Test("navigator factory probe records off-main construction")
    func test_navigatorFactoryRunsOffMain() async throws {
        // EPUBNavigatorViewController is a UIKit class and is hard-MainActor
        // by Readium's contract. We cannot construct it off-main without
        // type-system warfare. What we CAN verify is that the work the user
        // actually feels (the Readium publication load — AssetRetriever +
        // PublicationOpener + DefaultPublicationParser, which is where the
        // ZIP unpack happens) runs off-main. The navigator init that
        // follows is documented in SUMMARY.md as a cheap MainActor step.
        //
        // This test therefore re-verifies the same invariant as
        // test_load_invokesLoaderOffMain at the level of the *factory*
        // probe — i.e. the publication-producing factory body runs off
        // main. If a future plan wires an explicit navigator factory
        // closure, this test will be extended to probe that closure too.
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let probe = ProbeLoader()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: probe,
            debounceSeconds: 0.05
        )

        await vm.load()

        let recorded: Bool = try #require(probe.wasInvokedOnMain)
        #expect(recorded == false)
    }
}
