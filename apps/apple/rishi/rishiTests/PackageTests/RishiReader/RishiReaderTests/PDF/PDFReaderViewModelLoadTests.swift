@testable import rishi
import Testing
import Foundation
import os
import PDFKit




// MARK: - Phase 19 Plan 19-07 — F-P0-08 PDFDocument off-main load
//
// These tests pin three guarantees for `PDFReaderViewModel.load()`:
//
//   1. The `documentLoader` closure is invoked OFF the main thread (the
//      detached priority-elevated context is what shifts the multi-second
//      `PDFDocument(url:)` parse off main).
//   2. After load completes, observable state (`document`, `totalPages`)
//      is set and readable from MainActor — the post-load store mutations
//      are still safe to observe from SwiftUI.
//   3. A nil loader return is handled gracefully (no crash, no state
//      mutation, viewmodel stays in its empty state).
//
// The viewmodel exposes an internal `documentLoader` injection seam so the
// probe can capture `Thread.isMainThread` from inside the detached task body
// without spinning up a real PDF parse. Production callers use the default
// loader which wraps `PDFDocument(url:)`.

@Suite("PDFReaderViewModel.load() off-main", .serialized)
struct PDFReaderViewModelLoadTests {

    private func makeFixture(pageCount: Int) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("vm-load-\(UUID().uuidString).pdf")
        try RishiReader_FixtureBuilders.writeMultiPagePDF(to: url, pageCount: pageCount, withOutline: false)
        return url
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Load Fixture", formatType: .pdf, fileURL: "Books/x/load.pdf")
    }

    /// Captures `Thread.isMainThread` inside the loader body so the test can
    /// assert the viewmodel invoked it from a detached context.
    ///
    /// Uses `OSAllocatedUnfairLock` because `NSLock.lock()/unlock()` are
    /// unavailable from async contexts in Swift 6 strict mode.
    private final class ThreadProbe: @unchecked Sendable {
        private struct State {
            var wasMain: Bool?
            var called: Bool
        }
        private let storage = OSAllocatedUnfairLock<State>(initialState: State(wasMain: nil, called: false))

        var wasInvokedOnMain: Bool? {
            storage.withLock { $0.wasMain }
        }
        var wasCalled: Bool {
            storage.withLock { $0.called }
        }

        func record(isMain: Bool) {
            storage.withLock { state in
                state.wasMain = isMain
                state.called = true
            }
        }
    }

    /// Synchronous main-thread probe — `Thread.isMainThread` is unavailable
    /// from async contexts in Swift 6 strict, so callers hop through this
    /// non-async helper.
    nonisolated private static func isOnMainThreadSync() -> Bool {
        Thread.isMainThread
    }

    @Test("load() invokes documentLoader off the main thread")
    func test_load_constructsDocumentOffMain() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let url = try makeFixture(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = ThreadProbe()
        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05,
            documentLoader: { @Sendable loaderURL in
                probe.record(isMain: Self.isOnMainThreadSync())
                return PDFDocument(url: loaderURL)
            }
        )

        await vm.load()

        #expect(probe.wasCalled, "documentLoader was never invoked")
        let wasMain = try #require(probe.wasInvokedOnMain)
        #expect(wasMain == false, "documentLoader ran on the main thread — load() is not offloading")
    }

    @Test("load() assigns post-load state observable from main")
    func test_load_assignsStateOnMain() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let url = try makeFixture(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05
        )

        await vm.load()

        // Reading state from MainActor — viewmodel is @unchecked Sendable
        // but observable state mutations are intended to be visible here.
        await MainActor.run {
            #expect(vm.document != nil, "document was not assigned after load()")
            #expect(vm.totalPages == 4, "totalPages mismatch after load()")
        }
    }

    @Test("load() handles nil loader return without crashing or mutating state")
    func test_load_handlesNilDocument() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let url = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05,
            documentLoader: { @Sendable _ in nil }
        )

        await vm.load()

        await MainActor.run {
            #expect(vm.document == nil, "document should remain nil when loader returns nil")
            #expect(vm.totalPages == 0, "totalPages should stay 0 when loader returns nil")
            #expect(vm.outline.isEmpty, "outline should stay empty when loader returns nil")
        }
    }
}
