@testable import rishi
import Foundation
import Testing

private actor BulkPositionProbe: PositionStore {
    private let values: [BookID: Position]
    private(set) var bulkCalls = 0
    private(set) var singleCalls = 0
    private(set) var requestedIDs: Set<BookID> = []

    init(values: [BookID: Position]) { self.values = values }

    func position(for bookId: BookID) async throws -> Position? {
        singleCalls += 1
        return values[bookId]
    }

    func positions(for bookIDs: Set<BookID>) async throws -> [BookID: Position] {
        bulkCalls += 1
        requestedIDs = bookIDs
        return values
    }

    func counts() -> (bulk: Int, single: Int, requested: Set<BookID>) {
        (bulkCalls, singleCalls, requestedIDs)
    }

    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

@Suite("PositionLoader")
struct PositionLoaderTests {
    @Test("uses one bulk read, filters extra IDs, and omits missing positions")
    func usesOneBulkReadAndFiltersResults() async throws {
        let userID = UUID()
        let first = Book(userId: userID, title: "A", formatType: .pdf, fileURL: "a.pdf")
        let missing = Book(userId: userID, title: "Missing", formatType: .pdf, fileURL: "m.pdf")
        let unrequestedID = UUID()
        let saved = Position(bookId: first.id, locator: "saved", percentComplete: 0.4)
        let extra = Position(bookId: unrequestedID, locator: "extra", percentComplete: 0.9)
        let store = BulkPositionProbe(values: [first.id: saved, unrequestedID: extra])

        let result = await PositionLoader(positionStore: store).positions(for: [first, missing])

        #expect(result == [first.id: saved])
        let counts = await store.counts()
        #expect(counts.bulk == 1)
        #expect(counts.single == 0)
        #expect(counts.requested == Set([first.id, missing.id]))
    }

    @Test("empty input returns an empty map")
    func emptyInput() async {
        let loader = PositionLoader(positionStore: InMemoryPositionStore())
        #expect(await loader.positions(for: []).isEmpty)
    }
}
