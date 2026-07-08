import Foundation
import RishiCore
import RishiLibrary
import RishiSearch
import Testing
@testable import RishiVoice

@Suite("Real book context tool integration", .serialized)
struct RealBookToolContextIntegrationTests {

    @Test("imported real PDF indexes and search returns sourced context")
    func importedRealPDFSearchReturnsBookSourcedContext() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = try #require(
            Bundle.module.url(forResource: "how-to-prove-it", withExtension: "pdf")
        )
        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        let pdfExtractor = PdfTextExtractor()
        let indexingHook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": pdfExtractor]
        )
        let bookStore = InMemoryBookStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: [:],
            bookIndexingHook: indexingHook
        )

        let book = try await storage.importBook(from: sourceURL, ownerId: UUID())
        let importedURL = storage.absoluteFileURL(for: book)

        let extractedRows = try await pdfExtractor.extractParagraphs(from: importedURL)
        let target = try #require(extractedRows.first { row in
            row.text.localizedCaseInsensitiveContains("mathematical induction")
                && row.text.count > 120
        })

        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)
        let ready = await waitUntil(timeout: 45) {
            await search.status(bookId: book.id) == .ready
        }
        try #require(ready, "Imported book should finish indexing")

        let hits = try await search.search(queryText: target.text, bookId: book.id)
        let topHit = try #require(hits.first, "Imported book search should return a hit")
        #expect(topHit.text == target.text)
        #expect(topHit.page == target.page)
        #expect(topHit.text.localizedCaseInsensitiveContains("mathematical induction"))

        try await storage.delete(book)
    }

    @Test("imported real PDF tool call returns the same sourced context as direct search")
    func importedRealPDFToolCallReturnsBookSourcedContext() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = try #require(
            Bundle.module.url(forResource: "how-to-prove-it", withExtension: "pdf")
        )
        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        let pdfExtractor = PdfTextExtractor()
        let indexingHook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": pdfExtractor]
        )
        let bookStore = InMemoryBookStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: [:],
            bookIndexingHook: indexingHook
        )

        let book = try await storage.importBook(from: sourceURL, ownerId: UUID())
        let query = "What's the key idea I can learn from Chapter 4 of this book?"

        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)
        let ready = await waitUntil(timeout: 45) {
            await search.status(bookId: book.id) == .ready
        }
        try #require(ready, "Imported book should finish indexing")

        let directHits = try await search.search(queryText: query, bookId: book.id)
        let directTopHit = try #require(directHits.first, "direct search should return a hit")

        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let responder = BookContextResponder(client: fake, search: search, bookId: book.id)
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        defer { consumeTask.cancel() }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "chapter-4",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"\(query)\"}"
        ))

        let responded = await waitUntil(timeout: 10) {
            !fake.sentToolResultsSnapshot().isEmpty
        }
        try #require(responded, "tool call should yield a tool result")

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.callId == "chapter-4")
        #expect(sent.first?.payload != BookContextResponder.coldStartSentinel)
        #expect(sent.first?.payload != BookContextResponder.lookupFailedMessage)

        let payloadData = Data((sent.first?.payload ?? "").utf8)
        let parsed = try JSONSerialization.jsonObject(with: payloadData) as? [[String: Any]]
        let toolTopHitText = parsed?.first?["text"] as? String
        let toolTopHitPage = parsed?.first?["page"] as? Int

        #expect(parsed?.count ?? 0 >= 1, "tool call should return at least one passage")
        #expect(toolTopHitText == directTopHit.text)
        #expect(toolTopHitPage == directTopHit.page)
    }

    private func makeTempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealBookToolContext-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await predicate()
    }

    private func tempSourceCopy(of source: URL, named filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealBookToolContext-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }
}
