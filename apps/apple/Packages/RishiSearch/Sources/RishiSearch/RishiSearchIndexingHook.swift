import Foundation
import RishiCore
import RishiLibrary
import RishiLogging

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
/// + GRDB writes happen in that detached task. `IndexBuilder` writes
/// `index.status.json` (`.indexing` -> `.ready` or `.failed`) so the cold-start
/// sentinel in `USearchBookSearch.search` covers the in-flight window.
public final class RishiSearchIndexingHook: BookIndexingHook, @unchecked Sendable {
    private let builder: IndexBuilder
    private let extractors: [String: any PerBookTextExtractor]

    public init(
        builder: IndexBuilder,
        extractors: [String: any PerBookTextExtractor]
    ) {
        self.builder = builder
        self.extractors = extractors
    }

    public func scheduleIndexing(for book: Book, fileURL: URL) async {
        let ext = fileURL.pathExtension.lowercased()
        guard let extractor = extractors[ext] else {
            Log.event("rag.index.no_extractor", level: .warning, data: [
                "bookId": book.id.uuidString,
                "ext": ext,
            ])
            return
        }
        let bookId = book.id
        let builder = self.builder
        // Detached — returns immediately. CONTEXT.md: indexing is non-blocking,
        // failures surface via `index.status.json` (IndexBuilder writes the
        // sidecar). We log scheduling so the cold-start window is observable.
        Log.event("rag.index.scheduled", level: .info, data: [
            "bookId": bookId.uuidString,
            "ext": ext,
        ])
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
                    return
                }
                try await builder.buildIndex(bookId: bookId, paragraphs: paragraphs)
                Log.event("rag.index.scheduled.done", level: .info, data: [
                    "bookId": bookId.uuidString,
                    "paragraphs": String(paragraphs.count),
                ])
            } catch {
                Log.event("rag.index.scheduled.failed", level: .error, data: [
                    "bookId": bookId.uuidString,
                    "error": String(describing: error),
                ])
            }
        }
    }
}
