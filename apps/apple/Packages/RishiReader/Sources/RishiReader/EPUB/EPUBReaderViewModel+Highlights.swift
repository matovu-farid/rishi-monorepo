import Foundation
import Observation
import RishiCore
import RishiLogging

/// Highlight surface for ``EPUBReaderViewModel``.
///
/// Mirrors the shape of ``PDFReaderViewModel+Highlights`` (Phase 5
/// plan 05-06) — same `loadHighlights / createHighlight / updateNote /
/// deleteHighlight` contract, EPUB-specific locator wire format
/// (``EPUBHighlightLocator`` JSON, format tag `epub-v1`).
///
/// **Wire-format contract.** Both `Highlight.locatorStart` and
/// `Highlight.locatorEnd` get the same JSON payload for v1
/// — EPUB selections in the Phase-6 cut are treated as point
/// selections (one Readium `Locator` per highlight). If future range
/// selections need distinct CFI endpoints, that's a schema bump
/// (`epub-v2`) with a decoder fallback that still accepts `epub-v1`.
///
/// **Why a stored property here.** `EPUBReaderViewModel` is
/// `@Observable final class @unchecked Sendable` (matches the PDF VM
/// shape) so Swift extensions cannot add stored properties directly.
/// We hang the cache off a per-instance `ObjectIdentifier`-keyed
/// dictionary guarded by `NSLock`. `bumpHighlightsObservation()` touches
/// an already-tracked property (`theme`) so SwiftUI views that read
/// `loadedHighlights` re-evaluate when the cache mutates.
extension EPUBReaderViewModel {

    // MARK: - Cache plumbing

    fileprivate final class EPUBHighlightCacheBox: @unchecked Sendable {
        private var storage: [ObjectIdentifier: [Highlight]] = [:]
        private let lock = NSLock()

        func read(_ owner: EPUBReaderViewModel) -> [Highlight] {
            lock.lock(); defer { lock.unlock() }
            return storage[ObjectIdentifier(owner)] ?? []
        }
        func write(_ owner: EPUBReaderViewModel, _ value: [Highlight]) {
            lock.lock(); defer { lock.unlock() }
            storage[ObjectIdentifier(owner)] = value
        }
        func mutate(_ owner: EPUBReaderViewModel, _ body: (inout [Highlight]) -> Void) {
            lock.lock(); defer { lock.unlock() }
            var value = storage[ObjectIdentifier(owner)] ?? []
            body(&value)
            storage[ObjectIdentifier(owner)] = value
        }
        func clear(_ owner: EPUBReaderViewModel) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: ObjectIdentifier(owner))
        }
    }
    fileprivate static let highlightCache = EPUBHighlightCacheBox()

    // MARK: - Public API

    /// All loaded highlights for the current book — feeds the
    /// decoration applier and any future "highlights" sheet.
    public var loadedHighlights: [Highlight] {
        Self.highlightCache.read(self)
    }

    /// Loads every highlight for the current book from the store and
    /// seeds the cache. Errors degrade gracefully — no highlights, no
    /// crash, error logged through `Log.reader`.
    public func loadHighlights(from store: any HighlightStore) async {
        do {
            let rows = try await store.highlights(for: book.id)
            Self.highlightCache.write(self, rows)
            bumpHighlightsObservation()
        } catch {
            Log.reader.error(
                "Failed to load EPUB highlights: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Persists a new highlight from the selection coordinator's
    /// locator. Returns `nil` if encoding or persistence failed (logged
    /// for observability).
    @discardableResult
    public func createHighlight(
        color: HighlightColor,
        locator: EPUBHighlightLocator,
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
            Self.highlightCache.mutate(self) { $0.append(highlight) }
            bumpHighlightsObservation()
            return highlight
        } catch {
            Log.reader.error(
                "Failed to create EPUB highlight: \(error.localizedDescription, privacy: .public)"
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
            Self.highlightCache.mutate(self) { rows in
                if let idx = rows.firstIndex(where: { $0.id == updated.id }) {
                    rows[idx] = updated
                }
            }
            bumpHighlightsObservation()
        } catch {
            Log.reader.error(
                "Failed to update EPUB note: \(error.localizedDescription, privacy: .public)"
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
            Self.highlightCache.mutate(self) { rows in
                rows.removeAll { $0.id == highlight.id }
            }
            bumpHighlightsObservation()
        } catch {
            Log.reader.error(
                "Failed to delete EPUB highlight: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Observation

    /// `@Observable` cannot track mutations of an external cache
    /// directly, so we touch a property the framework already observes
    /// (`theme`) with an identity assignment. This wakes any view body
    /// that read `loadedHighlights` without changing visible state.
    private func bumpHighlightsObservation() {
        let current = self.theme
        self.theme = current
    }
}
