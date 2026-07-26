@testable import rishi
import Foundation
import Testing


@Suite("StubBookSearch fake")
struct StubBookSearchTests {

    @Test func defaultInitReturnsEmptyHitsAndReadyStatus() async throws {
        let stub = StubBookSearch()
        let bookId = UUID()

        let hits = try await stub.search(queryText: "what is power?", bookId: bookId)
        let status = await stub.status(bookId: bookId)

        #expect(hits.isEmpty)
        #expect(status == .ready)
        #expect(stub.searchCallCount() == 1)
    }

    @Test func setHitsRoundTripsThroughSearch() async throws {
        let stub = StubBookSearch()
        let staged = [
            BookSearchHit(text: "passage one", page: 12, score: 0.91),
            BookSearchHit(text: "passage two", page: 47, score: 0.74),
        ]
        stub.setHits(staged)

        let hits = try await stub.search(queryText: "anything", bookId: UUID())

        #expect(hits == staged)
    }

    @Test func setErrorIndexNotReadyThrows() async throws {
        let stub = StubBookSearch()
        stub.setError(BookContextSearchError.indexNotReady)

        await #expect(throws: BookContextSearchError.indexNotReady) {
            _ = try await stub.search(queryText: "q", bookId: UUID())
        }
    }

    @Test func searchCallCountIncrementsEvenWhenErrorThrows() async throws {
        let stub = StubBookSearch()
        stub.setError(.indexNotReady)

        for _ in 0..<3 {
            _ = try? await stub.search(queryText: "q", bookId: UUID())
        }

        #expect(stub.searchCallCount() == 3)
    }

    @Test func setStatusRoundTripsThroughStatus() async {
        let stub = StubBookSearch()
        let inProgress = BookSearchStatus.indexing(chunksDone: 3, chunksTotal: 10)
        stub.setStatus(inProgress)

        let status = await stub.status(bookId: UUID())

        #expect(status == inProgress)
    }

    @Test func lastQueryAndLastBookIdRecordTheMostRecentCall() async throws {
        let stub = StubBookSearch()
        let bookId = UUID()

        _ = try await stub.search(queryText: "first", bookId: UUID())
        _ = try await stub.search(queryText: "second", bookId: bookId)

        #expect(stub.lastQuery() == "second")
        #expect(stub.lastBookId() == bookId)
        #expect(stub.searchCallCount() == 2)
    }
}
