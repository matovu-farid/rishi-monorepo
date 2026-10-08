@testable import rishi
import Foundation
import Testing

@Suite("RishiDB position bulk reads")
struct PositionBulkReadTests {
    @Test("returns newest requested position and omits missing or unrequested IDs")
    func returnsNewestRequestedPositions() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let store = SwiftDataPositionStore(dbStore: db)
        let requestedID = UUID()
        let missingID = UUID()
        let otherID = UUID()
        let older = Position(bookId: requestedID, locator: "older", percentComplete: 0.2,
                             updatedAt: Date(timeIntervalSince1970: 100))
        let newer = Position(bookId: requestedID, locator: "newer", percentComplete: 0.8,
                             updatedAt: Date(timeIntervalSince1970: 200))
        let other = Position(bookId: otherID, locator: "other", percentComplete: 0.5,
                             updatedAt: Date(timeIntervalSince1970: 300))
        try await store.upsert(older)
        try await store.upsert(newer)
        try await store.upsert(other)

        let result = try await store.positions(for: [requestedID, missingID])

        #expect(result == [requestedID: newer])
        #expect(result[missingID] == nil)
        #expect(result[otherID] == nil)
    }
}
