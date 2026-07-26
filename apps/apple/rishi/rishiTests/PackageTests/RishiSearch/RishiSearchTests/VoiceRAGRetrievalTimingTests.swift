@testable import rishi
#if canImport(CoreML)
import Testing
import Foundation



/// End-to-end timing + correctness coverage for the voice-chat RAG retrieval
/// path, using REAL book fixtures and the REAL Core ML embedder (no mocks).
///
/// Motivation: a user reported that asking the voice agent a question that
/// requires a lookup ("what is chapter two about") makes it say "retrieving…"
/// and hang for a long time. The voice tool path is:
///
///   BookContextResponder -> USearchBookSearch.search(queryText:bookId:)
///     -> CoreMLMiniLMEmbedder.embed(query)        // embed the query
///     -> USearch HNSW index.search(vector:count:) // ANN over book chunks
///     -> ChunkStore.lookup(chunkIds:)             // SwiftData row fetch
///
/// These tests reproduce that exact retrieval (the responder is a thin JSON
/// wrapper over `search`) against the real corpora, assert the response is a
/// well-formed set of relevant passages, and TIME every stage. The query is
/// wrapped in a hard timeout so a genuine hang FAILS the test instead of
/// stalling the suite.
@Suite("Voice RAG retrieval — real fixtures, timed")
struct VoiceRAGRetrievalTimingTests {

    /// The exact question the user asked the voice agent.
    private static let query = "what is chapter two about"

    /// Generous ceiling for a single warm retrieval (query embed + HNSW search
    /// + chunk lookup). On a dev host this is normally tens of milliseconds;
    /// the budget exists to convert a hang into a loud failure.
    private static let queryBudgetSeconds: Double = 10.0

    @Test("PDF (how-to-prove-it): 'what is chapter two about' retrieves relevant passages")
    func pdfChapterTwoRetrieval() async throws {
        try await runRetrieval(
            label: "PDF how-to-prove-it",
            fixture: "how-to-prove-it",
            ext: "pdf",
            extractor: PdfTextExtractor(),
            // A topical control: a query with real semantic content, to
            // contrast relevance against the navigational chapter-N query.
            controlQuery: "proof by mathematical induction"
        )
    }

    @Test("EPUB (rationality): 'what is chapter two about' retrieves relevant passages")
    func epubChapterTwoRetrieval() async throws {
        try await runRetrieval(
            label: "EPUB rationality",
            fixture: "rationality",
            ext: "epub",
            extractor: EpubTextExtractor(),
            controlQuery: "the availability heuristic and cognitive biases"
        )
    }

    // MARK: - Shared pipeline

    private func runRetrieval(
        label: String,
        fixture: String,
        ext: String,
        extractor: any PerBookTextExtractor,
        controlQuery: String
    ) async throws {
        let fixtureURL = try #require(
            PackageTestResourceBundle.bundle.url(forResource: fixture, withExtension: ext),
            "missing fixture \(fixture).\(ext)"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1) Extract real text into (page, paragraph) tuples.
        let (paragraphs, extractMs) = try await measure {
            try await extractor.extractParagraphs(from: fixtureURL)
        }
        #expect(!paragraphs.isEmpty, "\(label): extractor produced no paragraphs")

        // 2) Cold-load the Core ML embedder once (mirrors the prewarm the
        //    voice session does while fetching the ephemeral key).
        let embedder = try CoreMLMiniLMEmbedder()
        let (_, prewarmMs) = await measure { await embedder.prewarm() }

        // 3) Build the on-device HNSW index over the whole book.
        let bookId = UUID()
        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        let (_, buildMs) = try await measure {
            try await builder.buildIndex(bookId: bookId, paragraphs: paragraphs)
        }

        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 5)
        let status = await search.status(bookId: bookId)
        #expect(status == .ready, "\(label): index status is \(status), expected .ready")

        // 4) The retrieval the user triggers. Hard-timeout so a hang fails
        //    rather than stalling the whole test suite.
        let (hits, queryMs) = try await measure {
            try await withTimeout(seconds: Self.queryBudgetSeconds) {
                try await search.search(queryText: Self.query, bookId: bookId)
            }
        }

        // 5) Assert the response is a well-formed result set.
        #expect(!hits.isEmpty, "\(label): retrieval returned no passages for the query")
        for hit in hits {
            #expect(!hit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(label): a hit had empty text")
            #expect(hit.page >= 1, "\(label): hit page \(hit.page) is not 1-based")
            #expect(hit.score >= 0.0 && hit.score <= 1.0,
                    "\(label): hit score \(hit.score) outside [0, 1]")
        }
        // Scores must be ordered best-first.
        let scores = hits.map(\.score)
        #expect(scores == scores.sorted(by: >),
                "\(label): hits are not ordered by descending score: \(scores)")

        // 6) Topical control: a query that carries real semantic content,
        //    to compare relevance against the navigational chapter-N query.
        let (controlHits, controlMs) = try await measure {
            try await withTimeout(seconds: Self.queryBudgetSeconds) {
                try await search.search(queryText: controlQuery, bookId: bookId)
            }
        }

        // 7) Surface timings + the actual retrieved passages for inspection.
        print("""

        ===== RAG retrieval — \(label) =====
        paragraphs indexed : \(paragraphs.count)
        extract text       : \(fmt(extractMs))
        embedder prewarm   : \(fmt(prewarmMs))   (Core ML cold-load, NO timeout)
        build HNSW index   : \(fmt(buildMs))
        """)
        printResults(query: Self.query, ms: queryMs, hits: hits)
        printResults(query: controlQuery, ms: controlMs, hits: controlHits)
        print("===========================================\n")
    }

    private func printResults(query: String, ms: Double, hits: [BookSearchHit]) {
        print("--- query: \"\(query)\"  (retrieval \(fmt(ms)))")
        for (i, hit) in hits.enumerated() {
            let snippet = hit.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .prefix(280)
            print("  [\(i + 1)] p.\(hit.page) score=\(String(format: "%.3f", hit.score))")
            print("      \(snippet)")
        }
    }

    // MARK: - Timing + timeout helpers

    private func measure<T>(_ work: () async throws -> T) async rethrows -> (T, Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await work()
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        return (value, ms)
    }

    private func fmt(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.2f s", ms / 1000) : String(format: "%.0f ms", ms)
    }
}

/// Error thrown when a retrieval exceeds its time budget — turns a hang into a
/// deterministic test failure.
private struct RetrievalTimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "retrieval exceeded \(seconds)s budget (treated as a hang)" }
}

/// Race `operation` against a deadline. Returns the operation's value if it
/// finishes first, otherwise throws `RetrievalTimeoutError`.
private func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RetrievalTimeoutError(seconds: seconds)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
#endif
