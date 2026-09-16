import Foundation
import Observation
import PDFKit



/// Highlight surface for ``PDFReaderViewModel``.
///
/// This extension layers persistence + caching on top of the page-tracking
/// VM landed in plan 05-05. The wire format for the locator string is
/// ``PDFHighlightLocator`` (encoded as JSON, stored verbatim in
/// `Highlight.locatorStart`). PDF highlights are point selections —
/// `locatorEnd` carries the same JSON so the row round-trips through the
/// `HighlightStore` contract unchanged. EPUB (Phase 6) will populate
/// `locatorStart`/`locatorEnd` with distinct CFI strings.
///
/// **Why a stored property here.** `PDFReaderViewModel` is `@Observable
/// final class @unchecked Sendable` (not `@MainActor`) — the existing
/// `pageIndex` state mutates from PDFKit notification callbacks. The same
/// shape is used for the highlights list so SwiftUI re-renders when
/// `loadHighlights` / `createHighlight` / `deleteHighlight` complete.
extension PDFReaderViewModel {

    // MARK: - Stored state
    //
    // Cached highlights for the currently-loaded book. Mirrors whatever
    // `HighlightStore.highlights(for: book.id)` last returned, plus any
    // optimistic mutations from `createHighlight`/`updateNote`/`deleteHighlight`.
    //
    // Property storage in an extension requires the `Storage` namespace
    // trick — Swift extensions cannot add stored properties directly. We
    // hang the cache off a per-instance `ObjectIdentifier` keyed dictionary
    // guarded by an unfair lock. The dictionary is `nonisolated(unsafe)`
    // because the VM itself is `@unchecked Sendable`; access is serialised
    // through the lock.

    /// Highlights filtered to the current page index, ready for the overlay.
    public var highlightsForCurrentPage: [Highlight] {
        let pageIdx = pageIndex
        return Self.cache.read(self).filter { row in
            (try? PDFHighlightLocator.decode(jsonString: row.locatorStart))?.page == pageIdx
        }
    }

    /// All loaded highlights — exposed for the future "highlights" sheet in
    /// plan 05-07 (and for tests that don't want to seek through pages).
    public var loadedHighlights: [Highlight] {
        Self.cache.read(self)
    }

    // MARK: - Cache plumbing

    fileprivate final class HighlightCacheBox: @unchecked Sendable {
        private var storage: [ObjectIdentifier: [Highlight]] = [:]
        private let lock = NSLock()

        func read(_ owner: PDFReaderViewModel) -> [Highlight] {
            lock.lock(); defer { lock.unlock() }
            return storage[ObjectIdentifier(owner)] ?? []
        }
        func write(_ owner: PDFReaderViewModel, _ value: [Highlight]) {
            lock.lock(); defer { lock.unlock() }
            storage[ObjectIdentifier(owner)] = value
        }
        func mutate(_ owner: PDFReaderViewModel, _ body: (inout [Highlight]) -> Void) {
            lock.lock(); defer { lock.unlock() }
            var value = storage[ObjectIdentifier(owner)] ?? []
            body(&value)
            storage[ObjectIdentifier(owner)] = value
        }
        func clear(_ owner: PDFReaderViewModel) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: ObjectIdentifier(owner))
        }
    }
    fileprivate static let cache = HighlightCacheBox()

    // MARK: - Public API

    /// Loads every highlight for the current book from the store and seeds the
    /// cache. Errors are logged via `Log.reader` — there is no thrown variant
    /// because the reader UI degrades gracefully (no highlights, no crash).
    public func loadHighlights(from store: any HighlightStore) async {
        do {
            let rows = try await store.highlights(for: book.id)
            Self.cache.write(self, rows)
            bumpHighlightsObservation()
        } catch {
            Log.reader.error(
                "Failed to load highlights: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Persists a new highlight from the selection coordinator's locator and
    /// appends it to the cache.
    ///
    /// PDFs are point selections — `locatorStart` and `locatorEnd` get the
    /// same JSON payload. EPUB (Phase 6) will diverge at the call site.
    ///
    /// - Returns: the saved `Highlight` on success; `nil` if encoding or
    ///   persistence failed (logged for observability).
    @discardableResult
    public func createHighlight(
        color: HighlightColor,
        locator: PDFHighlightLocator,
        note: String? = nil,
        store: any HighlightStore
    ) async -> Highlight? {
        do {
            let json = try locator.encodedJSONString()
            let highlight = Highlight(
                bookId: book.id,
                locatorStart: json,
                locatorEnd: json,
                color: color,
                text: locator.text,
                note: note,
                createdAt: Date()
            )
            try await store.upsert(highlight)
            NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            Self.cache.mutate(self) { $0.append(highlight) }
            bumpHighlightsObservation()
            return highlight
        } catch {
            Log.reader.error(
                "Failed to create highlight: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Sets / clears the note on an existing highlight and updates the cache.
    public func updateNote(
        on highlight: Highlight,
        note: String?,
        store: any HighlightStore
    ) async {
        var updated = highlight
        updated.note = note
        do {
            try await store.upsert(updated)
            NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            Self.cache.mutate(self) { rows in
                if let idx = rows.firstIndex(where: { $0.id == updated.id }) {
                    rows[idx] = updated
                }
            }
            bumpHighlightsObservation()
        } catch {
            Log.reader.error(
                "Failed to update note: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Deletes a highlight from the store and the cache.
    public func deleteHighlight(
        _ highlight: Highlight,
        store: any HighlightStore
    ) async {
        do {
            try await store.delete(highlight.id)
            NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            Self.cache.mutate(self) { rows in
                rows.removeAll { $0.id == highlight.id }
            }
            bumpHighlightsObservation()
        } catch {
            Log.reader.error(
                "Failed to delete highlight: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Observation

    /// `@Observable` cannot track mutations of an external cache directly,
    /// so we touch a property the framework already observes (`theme`) using
    /// an identity assignment. This forces a re-evaluation of any view body
    /// that read `highlightsForCurrentPage` without changing visible state.
    private func bumpHighlightsObservation() {
        let current = self.theme
        self.theme = current
    }
}
