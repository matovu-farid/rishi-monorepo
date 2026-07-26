import Foundation
import Observation



/// Highlight surface for ``ReaderViewModel``.
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
/// **Storage note.** `ReaderViewModel` is `@Observable final class
/// @unchecked Sendable` (not `@MainActor`). These CRUD methods are
/// `nonisolated async` — their array writes run on the generic executor
/// AFTER `await store.…` resumes, so two concurrent calls would race on a
/// plain stored array. The highlights cache therefore lives in an external
/// `NSLock`-guarded, `ObjectIdentifier`-keyed box (identical in shape to
/// ``PDFReaderViewModel+Highlights``). `@Observable` cannot track the
/// external box, so every mutation bumps a tracked property (`theme`) via an
/// identity assignment to force SwiftUI re-evaluation.
extension ReaderViewModel {

    // MARK: - Cached state

    /// All loaded highlights for the current book — read by
    /// ``ReaderScreen`` and ``EPUBHighlightInteractor`` to drive the
    /// in-page highlight overlay.
    public var loadedHighlights: [Highlight] {
        Self.cache.read(self)
    }

    // MARK: - Cache plumbing

    fileprivate final class HighlightCacheBox: @unchecked Sendable {
        private var storage: [ObjectIdentifier: [Highlight]] = [:]
        private let lock = NSLock()

        func read(_ owner: ReaderViewModel) -> [Highlight] {
            lock.lock(); defer { lock.unlock() }
            return storage[ObjectIdentifier(owner)] ?? []
        }
        func write(_ owner: ReaderViewModel, _ value: [Highlight]) {
            lock.lock(); defer { lock.unlock() }
            storage[ObjectIdentifier(owner)] = value
        }
        func mutate(_ owner: ReaderViewModel, _ body: (inout [Highlight]) -> Void) {
            lock.lock(); defer { lock.unlock() }
            var value = storage[ObjectIdentifier(owner)] ?? []
            body(&value)
            storage[ObjectIdentifier(owner)] = value
        }
        func clear(_ owner: ReaderViewModel) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: ObjectIdentifier(owner))
        }
    }
    fileprivate static let cache = HighlightCacheBox()

    // MARK: - Public API

    /// Loads every highlight for the current book from the store and
    /// seeds the cache. Errors degrade gracefully — no highlights, no
    /// crash, error logged through `Log.reader`.
    public func loadHighlights(from store: any HighlightStore) async {
        do {
            let rows = try await store.highlights(for: book.id)
            Self.cache.write(self, rows)
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
            Self.cache.mutate(self) { $0.append(highlight) }
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
            Self.cache.mutate(self) { rows in
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
            Self.cache.mutate(self) { rows in
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

    /// `@Observable` cannot track mutations of the external cache box
    /// directly, so we touch a property the framework already observes
    /// (`theme`) via an identity assignment. This forces a re-evaluation of
    /// any view body that read `loadedHighlights` without changing visible
    /// state.
    private func bumpHighlightsObservation() {
        let current = self.theme
        self.theme = current
    }
}
