import Foundation
import Observation
// `@preconcurrency` downgrades the Readium 3.x non-Sendable `Publication`
// sending diagnostics across its nonisolated async `search`/`next` boundaries,
// matching EPUBReadAloudCursor / ReaderViewModel / PublicationLoader.
@preconcurrency import ReadiumShared

/// Phase 37 Plan 37-05 — drives Readium's built-in full-text search for the
/// EPUB reader and resolves a chosen result back to its `Locator` for the jump.
///
/// `@Observable @MainActor`: SwiftUI reads `resultRows` / `isSearching` /
/// `query` directly from the shared search sheet, so all published state lives
/// on the main actor. The heavy work — paging Readium's `SearchIterator` — runs
/// inside a `Task` whose `await` points hop off-main; every write back to
/// `results` happens after the `await` resumes on the MainActor (the class is
/// `@MainActor`, so the continuation is main-isolated), keeping result writes
/// main-safe under Swift 6 strict concurrency.
///
/// Search uses Readium 3.9's default-installed `ContentSearchService` (EPUBParser
/// registers it automatically) — we just call `publication.search`. No custom
/// search-service registration is performed (RESEARCH Pitfall 1).
@Observable
@MainActor
public final class EPUBSearchModel {

    /// Live result locators, revealed progressively page-by-page as the iterator
    /// yields. Held as the source of truth so a tapped ``SearchResultRow`` can be
    /// resolved back to the `Locator` it was mapped from.
    public private(set) var results: [Locator] = []

    /// `true` from the start of a `search(_:)` until the iterator is exhausted
    /// (or the search fails / is cancelled) — drives the sheet's `ProgressView`.
    public private(set) var isSearching = false

    /// The current query text, bound to the search field in the sheet.
    public var query: String = ""

    /// The searchable publication. Held for the lifetime of the model.
    @ObservationIgnored private let publication: Publication

    /// The in-flight search task. Assigning a new job (or `nil`) cancels the
    /// previous one — this is the cancel-on-new-query guarantee: typing a fresh
    /// query abandons the prior iterator paging mid-flight.
    @ObservationIgnored private var job: Task<Void, Never>? {
        didSet { oldValue?.cancel() }
    }

    /// Stable row id per result index, so the mapper produces the same id on
    /// every recompute of `resultRows` and `locator(for:)` can match it back.
    @ObservationIgnored private var rowIDs: [UUID] = []

    public init(publication: Publication) {
        self.publication = publication
    }

    // MARK: - Search lifecycle

    /// Runs a new search for `query`, cancelling any in-flight search first.
    ///
    /// An empty (or whitespace-only) query clears results and does nothing else.
    /// Otherwise the iterator is paged inside a cancellable `Task`; each page's
    /// locators are appended to `results` as they arrive (progressive reveal),
    /// and `isSearching` flips false when the iterator is exhausted.
    public func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel()
            results = []
            rowIDs = []
            return
        }

        // Robustness only — Readium installs the search service by default for
        // EPUB, so this is expected to be true. We do NOT register a factory.
        guard publication.isSearchable else {
            results = []
            rowIDs = []
            isSearching = false
            return
        }

        results = []
        rowIDs = []
        isSearching = true

        job = Task { [publication] in
            switch await publication.search(query: trimmed) {
            case .success(let iterator):
                var accumulated: [Locator] = []
                pageLoop: while true {
                    if Task.isCancelled { break }
                    switch await iterator.next() {
                    case .success(let collection?):
                        if Task.isCancelled { break pageLoop }
                        accumulated.append(contentsOf: collection.locators)
                        // Resumes on the MainActor (class is @MainActor), so
                        // these writes are main-isolated even though `next()`
                        // suspended off-main. Progressive reveal.
                        self.results = accumulated
                        self.rowIDs = accumulated.map { _ in UUID() }
                    case .success(nil):
                        // Iterator exhausted.
                        break pageLoop
                    case .failure:
                        break pageLoop
                    }
                }
                self.isSearching = false
            case .failure:
                self.results = []
                self.rowIDs = []
                self.isSearching = false
            }
        }
    }

    /// Cancels any in-flight search. Leaves already-found `results` in place so
    /// the sheet keeps showing the last query's hits until a new search starts.
    public func cancel() {
        job?.cancel()
        job = nil
        isSearching = false
    }

    // MARK: - Shared-view bridging

    /// Maps the engine-specific `[Locator]` into the engine-agnostic rows
    /// consumed by ``SearchResultsView`` (shared with the PDF reader). Each row's
    /// id is the stable per-index id so ``locator(for:)`` resolves the tap.
    public var resultRows: [SearchResultRow] {
        zip(results.indices, results).map { index, locator in
            let id = index < rowIDs.count ? rowIDs[index] : UUID()
            return EPUBSearchResultMapper.row(from: locator, id: id)
        }
    }

    /// Looks up the `Locator` backing a tapped ``SearchResultRow`` (they share
    /// the same per-index id), so the screen can jump via the navigator.
    public func locator(for row: SearchResultRow) -> Locator? {
        guard let index = rowIDs.firstIndex(of: row.id), index < results.count else {
            return nil
        }
        return results[index]
    }
}
