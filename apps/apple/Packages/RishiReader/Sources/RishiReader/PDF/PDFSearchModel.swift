import Foundation
import Observation
@preconcurrency import PDFKit

/// Phase 37 Plan 37-04 — drives PDFKit's incremental in-book search and the
/// jump/highlight of a chosen result.
///
/// `@Observable @MainActor`: SwiftUI reads `results` / `isSearching` / `query`
/// directly from the search sheet, so all published state lives on the main
/// actor. The actual text scan is delegated to PDFKit's
/// `PDFDocument.beginFindString(_:withOptions:)`, which walks the document on a
/// background queue and posts `.PDFDocumentDidFindMatch` per hit; the
/// notification handler hops back to the MainActor before mutating `results`,
/// so result-array writes are never made off-main (RESEARCH §"PDF incremental
/// search").
///
/// `@unchecked Sendable` is unnecessary here — the class is `@MainActor`, and
/// the only non-Sendable state it holds (`PDFDocument` / `PDFSelection`) is
/// constructed and read on the main actor. PDFKit is imported `@preconcurrency`
/// so the non-`Sendable` PDFKit types don't trip strict-concurrency diagnostics
/// when captured in the notification closures.
@Observable
@MainActor
public final class PDFSearchModel {

    /// Live result rows, appended one-per-match as PDFKit reports them.
    public private(set) var results: [PDFSearchResult] = []

    /// `true` between the start of a `search(_:in:)` and the
    /// `.PDFDocumentDidEndFind` notification — drives the sheet's `ProgressView`.
    public private(set) var isSearching = false

    /// The current query text, bound to the search field in the sheet.
    public var query: String = ""

    /// The document currently being searched; held so `cancel()` can stop an
    /// in-flight scan.
    @ObservationIgnored private weak var activeDocument: PDFDocument?

    /// Parallel store of the live `PDFSelection` for each result id, so
    /// `jump(to:in:)` can hand PDFKit the real selection (the row model is
    /// deliberately PDFKit-free). Not observed — UI never reads selections.
    @ObservationIgnored private var selectionsByResultID: [UUID: PDFSelection] = [:]

    @ObservationIgnored private var matchObserver: NSObjectProtocol?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    public init() {}

    // MARK: - Search lifecycle

    /// Starts an incremental PDFKit search for `query` in `document`. Cancels
    /// any in-flight search, clears prior results, and (for a non-empty query)
    /// registers notification observers and kicks off `beginFindString`.
    ///
    /// `beginFindString` performs the heavy scan off the MainActor; each match
    /// arrives via `.PDFDocumentDidMatchString` whose handler marshals back to
    /// the MainActor before appending, keeping `results` writes main-isolated.
    public func search(_ query: String, in document: PDFDocument) {
        cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeDocument = document
        isSearching = true

        let center = NotificationCenter.default
        matchObserver = center.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: document,
            queue: .main
        ) { [weak self] note in
            // `note.object` is the searching `PDFDocument` (PDFKit posts self),
            // so the index lookup needs no captured non-Sendable document — the
            // `@Sendable` notification closure stays capture-clean.
            guard
                let self,
                let matchedDocument = note.object as? PDFDocument,
                let selection = note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection,
                let firstPage = selection.pages.first
            else { return }
            let page = matchedDocument.index(for: firstPage)
            let result = PDFSearchResult(
                page: page,
                snippet: PDFSearchResult.snippet(from: selection.string ?? "")
            )
            self.selectionsByResultID[result.id] = selection
            self.results.append(result)
        }
        endObserver = center.addObserver(
            forName: .PDFDocumentDidEndFind,
            object: document,
            queue: .main
        ) { [weak self] _ in
            self?.isSearching = false
        }

        document.beginFindString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Cancels any in-flight search, removes observers, and clears results +
    /// stored selections.
    public func cancel() {
        activeDocument?.cancelFindString()
        if let matchObserver { NotificationCenter.default.removeObserver(matchObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        matchObserver = nil
        endObserver = nil
        activeDocument = nil
        isSearching = false
        results.removeAll()
        selectionsByResultID.removeAll()
    }

    // MARK: - Jump / highlight

    /// Jumps the live `pdfView` to a chosen result and highlights the match,
    /// using the stored `PDFSelection` captured when the match was reported.
    public func jump(to result: PDFSearchResult, in pdfView: PDFView) {
        guard let selection = selectionsByResultID[result.id] else { return }
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: true)
    }

    // MARK: - Shared-view bridging

    /// Maps the engine-specific `[PDFSearchResult]` into the engine-agnostic
    /// rows consumed by ``SearchResultsView`` (shared with EPUB search). The
    /// 0-based `page` is presented 1-based ("Page N").
    public var resultRows: [SearchResultRow] {
        results.map { result in
            SearchResultRow(
                id: result.id,
                title: "Page \(result.page + 1)",
                subtitle: result.snippet
            )
        }
    }

    /// Looks up the `PDFSearchResult` backing a shared `SearchResultRow` (they
    /// share the same `id`), so the screen can call ``jump(to:in:)`` on select.
    public func result(for row: SearchResultRow) -> PDFSearchResult? {
        results.first { $0.id == row.id }
    }
}
