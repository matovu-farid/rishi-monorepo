import Foundation

private actor IndexingInFlightClaims {
    private var bookIDs: Set<UUID> = []

    func claim(_ bookID: UUID) -> Bool {
        guard bookIDs.insert(bookID).inserted else { return false }
        return true
    }

    func release(_ bookID: UUID) {
        bookIDs.remove(bookID)
    }
}



/// Production `BookIndexingHook` conformer that wires `IndexBuilder`
/// (Plan 25-05) to a per-format `PerBookTextExtractor` (Plan 25-11). One
/// instance is constructed in `AppDependencies.buildServices` and passed to
/// `BookFileStorage` so every import schedules a detached background index
/// build.
///
/// Routing:
///   - `fileURL.pathExtension.lowercased()` -> `extractors[ext]`.
///   - Unknown extension -> log `rag.index.no_extractor` and return.
///
/// Lifetime: the hook itself returns immediately after spawning a
/// `Task.detached(priority: .background)` — the extraction + embedding + USearch
/// + SwiftData writes happen in that detached task. `IndexBuilder` writes
/// `index.status.json` (`.indexing` -> `.ready` or `.failed`) so the cold-start
/// sentinel in `USearchBookSearch.search` covers the in-flight window.
public final class RishiSearchIndexingHook: BookIndexingHook, @unchecked Sendable {
    private let builder: IndexBuilder
    private let extractors: [String: any PerBookTextExtractor]
    private let onIndexReady: (@Sendable (UUID) async -> Void)?
    private let inFlightClaims = IndexingInFlightClaims()

    public init(
        builder: IndexBuilder,
        extractors: [String: any PerBookTextExtractor],
        onIndexReady: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.builder = builder
        self.extractors = extractors
        self.onIndexReady = onIndexReady
    }

    public func scheduleIndexing(for book: Book, fileURL: URL) async {
        let ext = fileURL.pathExtension.lowercased()
        let bookId = book.id
        let builder = self.builder
        let onIndexReady = self.onIndexReady
        guard let extractor = extractors[ext] else {
            Log.event("rag.index.no_extractor", level: .warning, data: [
                "bookId": bookId.uuidString,
                "ext": ext,
            ])
            // No extractor means we will never call buildIndex, so the status
            // sidecar would stay missing (.notIndexed) and the reader would
            // re-schedule indexing on every open. Mark .failed (terminal) so
            // shouldBackfillIndex skips it and the chip stops polling.
            await builder.markFailed(bookId: bookId, reason: "no extractor for .\(ext)")
            return
        }
        guard await inFlightClaims.claim(bookId) else {
            Log.event("rag.index.coalesced", level: .info, data: [
                "bookId": bookId.uuidString,
                "ext": ext,
            ])
            return
        }
        let inFlightClaims = self.inFlightClaims
        // Detached — returns immediately. CONTEXT.md: indexing is non-blocking,
        // failures surface via `index.status.json` (IndexBuilder writes the
        // sidecar). We log scheduling so the cold-start window is observable.
        Log.event("rag.index.scheduled", level: .info, data: [
            "bookId": bookId.uuidString,
            "ext": ext,
        ])
        await builder.markIndexing(bookId: bookId)
        Task.detached(priority: .background) {
            do {
                let paragraphs = try await extractor.extractParagraphs(from: fileURL)
                guard !paragraphs.isEmpty else {
                    Log.event("rag.index.empty_paragraphs", level: .warning, data: [
                        "bookId": bookId.uuidString,
                    ])
                    // IndexBuilder still records `.ready` if we call it with
                    // an empty list (degenerate but valid). Call it so the
                    // sidecar moves out of `.notIndexed` and the cold-start
                    // sentinel doesn't stick.
                    try await builder.buildIndex(bookId: bookId, paragraphs: [])
                    await inFlightClaims.release(bookId)
                    await onIndexReady?(bookId)
                    return
                }
                try await builder.buildIndex(bookId: bookId, paragraphs: paragraphs)
                await inFlightClaims.release(bookId)
                await onIndexReady?(bookId)
                Log.event("rag.index.scheduled.done", level: .info, data: [
                    "bookId": bookId.uuidString,
                    "paragraphs": String(paragraphs.count),
                ])
            } catch {
                Log.event("rag.index.scheduled.failed", level: .error, data: [
                    "bookId": bookId.uuidString,
                    "error": String(describing: error),
                ])
                // The throw happened before buildIndex could write the sidecar,
                // so status would be stuck at .notIndexed. Mark .failed
                // (terminal) so shouldBackfillIndex skips it (no reader-open
                // thrash) and the chip stops polling.
                await builder.markFailed(
                    bookId: bookId,
                    reason: String(describing: error)
                )
                await inFlightClaims.release(bookId)
            }
        }
    }
}
