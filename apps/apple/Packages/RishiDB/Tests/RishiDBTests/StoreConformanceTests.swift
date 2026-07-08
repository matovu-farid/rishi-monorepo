import Foundation
import Testing
import RishiCore
import RishiTesting
@testable import RishiDB

/// Run every RishiTesting conformance helper against the SwiftData-backed stores.
@Suite("RishiDB store conformance")
struct StoreConformanceTests {

    private func makeStore() throws -> RishiDBStore {
        try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
    }

    @Test func bookStoreSatisfiesContract() async throws {
        let store = SwiftDataBookStore(dbStore: try makeStore())
        try await assertBookStoreConformance(store)
    }

    @Test func highlightStoreSatisfiesContract() async throws {
        let store = SwiftDataHighlightStore(dbStore: try makeStore())
        try await assertHighlightStoreConformance(store)
    }

    @Test func bookmarkStoreSatisfiesContract() async throws {
        let store = SwiftDataBookmarkStore(dbStore: try makeStore())
        try await assertBookmarkStoreConformance(store)
    }

    @Test func positionStoreSatisfiesContract() async throws {
        let store = SwiftDataPositionStore(dbStore: try makeStore())
        try await assertPositionStoreConformance(store)
    }

    @Test func conversationStoreSatisfiesContract() async throws {
        let store = SwiftDataConversationStore(dbStore: try makeStore())
        try await assertConversationStoreConformance(store)
    }

    @Test func messageStoreSatisfiesContract() async throws {
        let store = SwiftDataMessageStore(dbStore: try makeStore())
        try await assertMessageStoreConformance(store)
    }
}
