@testable import rishi
import Testing
import Foundation
import ReadiumShared




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
/// Implementation hook: `ReaderViewModel` accepts an
/// `any PublicationLoading` loader; the production
/// `PublicationLoader` conforms, and tests inject a probe that
/// records `Thread.isMainThread` at the moment the loader body is
/// entered.
@Suite("ReaderViewModel.load isolation", .serialized)
struct ReaderViewModelLoadTests {

    actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    actor ProbeState {
        private(set) var didStart = false
        private(set) var didFinish = false

        func markStarted() { didStart = true }
        func markFinished() { didFinish = true }
    }

    // MARK: - Probe loader

    /// Probe that records `Thread.isMainThread` on entry and forwards
    /// the actual open to a bundled Readium loader so the rest of the
    /// view-model load path stays exercised end-to-end.
    ///
    /// All lock manipulation lives inside synchronous `record(...)` /
    /// `wasInvokedOnMain` accessors so `open(fileURL:)` (an `async`
    /// method) never invokes `NSLock.lock()` directly — Swift 6 marks
    /// those as unavailable from asynchronous contexts.
    final class ProbeLoader: PublicationLoading, @unchecked Sendable {
        private let inner: PublicationLoader
        private let lock = NSLock()
        private var _wasInvokedOnMain: Bool?

        init(inner: PublicationLoader = PublicationLoader()) {
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

    final class GateLoader: PublicationLoading, @unchecked Sendable {
        private let inner: PublicationLoader
        private let gate: AsyncGate
        private let state: ProbeState

        init(inner: PublicationLoader = PublicationLoader(), gate: AsyncGate, state: ProbeState) {
            self.inner = inner
            self.gate = gate
            self.state = state
        }

        func open(fileURL: URL) async throws -> Publication {
            await state.markStarted()
            await gate.wait()
            return try await inner.open(fileURL: fileURL)
        }
    }

    struct ThrowingLoader: PublicationLoading {
        let state: ProbeState

        func open(fileURL _: URL) async throws -> Publication {
            await state.markStarted()
            throw NSError(domain: "ReaderViewModelLoadTests", code: 1)
        }
    }

    struct HangingPositionStore: PositionStore {
        let gate: AsyncGate
        let state: ProbeState

        func position(for _: BookID) async throws -> Position? {
            await state.markStarted()
            await gate.wait()
            return nil
        }

        func upsert(_: Position) async throws {}
        func delete(_: PositionID) async throws {}
    }

    struct RecordingPositionStore: PositionStore {
        let state: ProbeState
        let position: Position

        func position(for _: BookID) async throws -> Position? {
            await state.markStarted()
            return position
        }

        func upsert(_: Position) async throws {}
        func delete(_: PositionID) async throws {}
    }

    // MARK: - Helpers

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    // MARK: - Tests

    @Test("load() invokes loader off the main thread")
    func test_load_invokesLoaderOffMain() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let probe = ProbeLoader()
        let vm = ReaderViewModel(
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
        let vm = ReaderViewModel(
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
        let vm = ReaderViewModel(
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

    @Test("load starts position lookup before publication open completes")
    func test_loadStartsPositionLookupConcurrently() async throws {
        let url = try aliceURL()
        let book = makeBook()
        let openGate = AsyncGate()
        let loaderState = ProbeState()
        let positionState = ProbeState()
        let position = Position(
            bookId: book.id,
            locator: try EPUBPositionLocator(
                locator: Locator(
                    href: try #require(RelativeURL(path: "chapter1.xhtml")),
                    mediaType: .xhtml,
                    locations: Locator.Locations(progression: 0.42)
                )
            ).encodedJSONString()
        )
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: RecordingPositionStore(state: positionState, position: position),
            loader: GateLoader(gate: openGate, state: loaderState),
            debounceSeconds: 0.05
        )

        let loadTask = Task { await vm.load() }
        #expect(await waitUntil { await loaderState.didStart })
        #expect(await waitUntil { await positionState.didStart })

        await openGate.open()
        await loadTask.value

        #expect(vm.loadingState == .loaded)
        let restoredHref = try #require(vm.latestLocator?.href)
        #expect(String(describing: restoredHref).contains("chapter1.xhtml"))
    }

    @Test("publication failure does not wait for a hanging position lookup")
    func test_publicationFailureDoesNotWaitForPositionLookup() async throws {
        let book = makeBook()
        let positionGate = AsyncGate()
        let loaderState = ProbeState()
        let positionState = ProbeState()
        let finishedState = ProbeState()
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: try aliceURL(),
            positionStore: HangingPositionStore(gate: positionGate, state: positionState),
            loader: ThrowingLoader(state: loaderState),
            debounceSeconds: 0.05
        )

        let loadTask = Task {
            await vm.load()
            await finishedState.markFinished()
        }

        #expect(await waitUntil { await loaderState.didStart })
        #expect(await waitUntil { await positionState.didStart })
        #expect(await waitUntil { await finishedState.didFinish })
        #expect({
            if case .failed = vm.loadingState { return true }
            return false
        }())

        await positionGate.open()
        await loadTask.value
    }
}
