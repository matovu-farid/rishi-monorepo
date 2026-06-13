import Testing
import Foundation
import PDFKit
import RishiCore
import RishiTesting
@testable import RishiReader

// MARK: - Phase 21 Plan 21-03 — cold-open loading indicator
//
// Pins the four lifecycle transitions of `PDFReaderViewModel.loadingState`:
//
//   1. A freshly-constructed VM starts in `.idle`.
//   2. After `load()` returns and the document is bound, state is `.loaded`.
//   3. When the documentLoader returns nil, state is `.failed(reason:)`.
//   4. During the in-flight detached parse, state is `.loading`.
//
// The `documentLoader` injection seam (the same one used by Phase 19
// `PDFReaderViewModelLoadTests`) lets these tests drive the lifecycle
// without spinning up a real multi-second PDF parse.

@Suite("PDFReaderViewModel.loadingState lifecycle", .serialized)
struct PDFReaderViewModelLoadingStateTests {

    private func makeFixture(pageCount: Int) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("loadingstate-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: pageCount, withOutline: false)
        return url
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Loading State Fixture", formatType: .pdf, fileURL: "Books/x/state.pdf")
    }

    @Test("starts in .idle before load() runs")
    func test_startsIdle() async throws {
        let store = InMemoryPositionStore()
        let url = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05
        )

        #expect(vm.loadingState == .idle, "VM should start idle until load() is invoked")
    }

    @Test("transitions to .loaded after successful load()")
    func test_transitionsToLoadedOnSuccess() async throws {
        let store = InMemoryPositionStore()
        let url = try makeFixture(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05
        )

        await vm.load()

        #expect(vm.loadingState == .loaded, "VM should be .loaded after load() returns with a valid document")
    }

    @Test("transitions to .failed when documentLoader returns nil")
    func test_transitionsToFailedOnNilDocument() async throws {
        let store = InMemoryPositionStore()
        let url = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05,
            documentLoader: { @Sendable _ in nil }
        )

        await vm.load()

        // Pattern-match the .failed case; the test does not assert on the
        // exact reason string (that is part of the VM's contract with the
        // failure overlay, not the lifecycle invariant).
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
        let store = InMemoryPositionStore()
        let url = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: makeBook(),
            userId: UUID(),
            documentURL: url,
            positionStore: store,
            debounceSeconds: 0.05,
            documentLoader: { @Sendable loaderURL in
                // Suspend long enough for the caller to observe .loading.
                try? await Task.sleep(for: .milliseconds(100))
                return PDFDocument(url: loaderURL)
            }
        )

        // Kick off load on a detached Task so we can sample the VM
        // mid-flight without blocking the caller.
        let loadTask = Task { await vm.load() }

        // Give the VM a moment to enter the .loading branch.
        try await Task.sleep(for: .milliseconds(30))

        #expect(vm.loadingState == .loading, "VM should be .loading while the detached parse is in flight")

        await loadTask.value
        #expect(vm.loadingState == .loaded)
    }
}
