import Testing
import Foundation
import ReadiumShared
import RishiCore
import RishiTesting
@testable import RishiReader

// MARK: - Phase 21 Plan 21-03 — cold-open loading indicator
//
// Pins the four lifecycle transitions of `EPUBReaderViewModel.loadingState`:
//
//   1. A freshly-constructed VM starts in `.idle`.
//   2. After `load()` returns and the publication is bound, state is
//      `.loaded`.
//   3. When the injected loader throws, state is `.failed(reason:)`.
//   4. During the in-flight detached parse, state is `.loading`.
//
// Success cases reuse the bundled `alice.epub` fixture through the real
// `EPUBPublicationLoader`. The failure-path tests inject a stub loader
// that throws — Readium `Publication` is not constructible in tests, so
// only the throw path is faked. The "during parse" probe wraps the real
// loader and inserts a small sleep so the test can sample mid-flight.

@Suite("EPUBReaderViewModel.loadingState lifecycle", .serialized)
struct EPUBReaderViewModelLoadingStateTests {

    // MARK: - Helpers

    private func aliceURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "alice", withExtension: "epub"))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub")
    }

    // MARK: - Stub loaders

    /// Always throws — exercises the .failed branch.
    private final class ThrowingLoader: EPUBPublicationLoading, @unchecked Sendable {
        let error: EPUBPublicationLoaderError
        init(error: EPUBPublicationLoaderError = .publicationOpenFailed("stub failure")) {
            self.error = error
        }
        func open(fileURL: URL) async throws -> Publication {
            throw error
        }
    }

    /// Sleeps before forwarding to the real loader — gives the test a
    /// window to sample `.loading` mid-flight.
    private final class SlowLoader: EPUBPublicationLoading, @unchecked Sendable {
        let inner: EPUBPublicationLoader
        let delay: Duration
        init(delay: Duration = .milliseconds(100)) {
            self.inner = EPUBPublicationLoader()
            self.delay = delay
        }
        func open(fileURL: URL) async throws -> Publication {
            try? await Task.sleep(for: delay)
            return try await inner.open(fileURL: fileURL)
        }
    }

    // MARK: - Tests

    @Test("starts in .idle before load() runs")
    func test_startsIdle() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: EPUBPublicationLoader(),
            debounceSeconds: 0.05
        )

        #expect(vm.loadingState == .idle, "VM should start idle until load() is invoked")
    }

    @Test("transitions to .loaded after successful load()")
    func test_transitionsToLoadedOnSuccess() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: EPUBPublicationLoader(),
            debounceSeconds: 0.05
        )

        await vm.load()

        #expect(vm.loadingState == .loaded, "VM should be .loaded after load() returns with a publication")
    }

    @Test("transitions to .failed when loader throws")
    func test_transitionsToFailedOnLoaderThrow() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: ThrowingLoader(),
            debounceSeconds: 0.05
        )

        await vm.load()

        switch vm.loadingState {
        case .failed:
            // expected
            break
        default:
            Issue.record("Expected .failed, got \(vm.loadingState)")
        }
    }

    @Test("exposes .loading during the detached parse")
    func test_exposesLoadingDuringDetachedParse() async throws {
        let url = try aliceURL()
        let store = InMemoryPositionStore()
        let vm = EPUBReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            loader: SlowLoader(delay: .milliseconds(150)),
            debounceSeconds: 0.05
        )

        let loadTask = Task { await vm.load() }

        // Sample mid-flight.
        try await Task.sleep(for: .milliseconds(40))
        #expect(vm.loadingState == .loading, "VM should be .loading while the detached parse is in flight")

        await loadTask.value
        #expect(vm.loadingState == .loaded)
    }
}
