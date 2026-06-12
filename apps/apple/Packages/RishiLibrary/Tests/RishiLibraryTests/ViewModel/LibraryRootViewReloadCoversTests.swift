import Testing
import Foundation
@testable import RishiCore
@testable import RishiLibrary

/// Phase 19 Plan 19-02 — F-P0-02.
///
/// `LibraryRootView.reloadCovers()` used to await `viewModel.coverURL(for:)`
/// once per book in a serial `for` loop. For a 50-book library that's 50
/// sequential MainActor hops + 50 sync `FileManager.fileExists` calls on the
/// paint task. We replace the loop with `withTaskGroup` parallel fan-out per
/// Swift book — "Calling Asynchronous Functions in Parallel".
///
/// The production `reloadCovers()` is a private SwiftUI view method, so we
/// surface the parallelisable kernel as a `nonisolated static` method on
/// `LibraryRootView` — `computeCoverURLs(books:coverURLFor:)` — and assert
/// concurrency at that seam. The private wrapper still owns the @State
/// assignment.
@Suite("LibraryRootView reloadCovers fan-out")
struct LibraryRootViewReloadCoversTests {

    private static let oneHundredMillis: UInt64 = 100_000_000

    /// Build a slow `coverURLFor` closure that sleeps `sleepNanos` per call
    /// and returns a deterministic URL keyed off the book id.
    private static func slowProbe(sleepNanos: UInt64) -> @Sendable (Book) async -> URL? {
        { book in
            try? await Task.sleep(nanoseconds: sleepNanos)
            return URL(string: "file:///cover/\(book.id.uuidString).png")
        }
    }

    /// Build a probe that returns nil for every other book in the input list.
    /// Used to assert the result map omits nil resolutions without crashing.
    private static func nilEveryOtherProbe(books: [Book]) -> @Sendable (Book) async -> URL? {
        let nilSet: Set<BookID> = Set(books.enumerated().compactMap { idx, b in
            idx.isMultiple(of: 2) ? b.id : nil
        })
        return { book in
            if nilSet.contains(book.id) { return nil }
            return URL(string: "file:///cover/\(book.id.uuidString).png")
        }
    }

    private static func books(_ n: Int) -> [Book] {
        (0..<n).map { i in
            LibraryFixture.book(title: "Book #\(i)")
        }
    }

    // MARK: - Test 1: Concurrent fan-out (the load-bearing assertion)

    @Test("reloadCovers fans out N cover lookups concurrently — 10 books × 100ms < 300ms wall")
    func test_reloadCovers_fansOutConcurrently() async {
        let booksList = Self.books(10)
        let probe = Self.slowProbe(sleepNanos: Self.oneHundredMillis)

        let start = DispatchTime.now()
        let result = await LibraryRootView.computeCoverURLs(books: booksList, coverURLFor: probe)
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        // Serial would be ≥ 1_000_000_000 ns (1s). Parallel should be in the
        // 100-200ms range. We allow up to 300ms to absorb CI variance.
        let elapsedMillis = elapsedNanos / 1_000_000
        #expect(elapsedMillis < 300, "Expected < 300ms (parallel); got \(elapsedMillis)ms. Likely still serial.")
        #expect(result.count == booksList.count)
    }

    // MARK: - Test 2: Result map preserves all non-nil resolutions

    @Test("reloadCovers result map contains every book that resolves to a non-nil URL")
    func test_reloadCovers_resultMapPreservesAllPairs() async {
        let booksList = Self.books(7)
        let probe = Self.slowProbe(sleepNanos: 1_000_000) // 1ms — fast

        let result = await LibraryRootView.computeCoverURLs(books: booksList, coverURLFor: probe)

        #expect(result.count == booksList.count)
        for book in booksList {
            let expected = URL(string: "file:///cover/\(book.id.uuidString).png")
            #expect(result[book.id] == expected, "Missing or wrong URL for book \(book.id)")
        }
    }

    // MARK: - Test 3: Nil URLs are absent from the dictionary (no crash)

    @Test("reloadCovers omits books whose coverURLFor returned nil, no crash")
    func test_reloadCovers_handlesNilUrlsGracefully() async {
        let booksList = Self.books(6)
        let probe = Self.nilEveryOtherProbe(books: booksList)

        let result = await LibraryRootView.computeCoverURLs(books: booksList, coverURLFor: probe)

        // Half the books return nil (every other one). Result map omits them.
        for (idx, book) in booksList.enumerated() {
            if idx.isMultiple(of: 2) {
                #expect(result[book.id] == nil, "Book at even index should be absent (nil URL)")
            } else {
                #expect(result[book.id] != nil, "Book at odd index should be present")
            }
        }
        #expect(result.count == booksList.count / 2)
    }
}
