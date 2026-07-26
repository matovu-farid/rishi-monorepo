@testable import rishi
import Foundation
import Testing



@Suite("In-memory stores satisfy conformance")
struct InMemoryStoresConformanceTests {

    @Test func bookStoreConforms() async throws {
        try await assertBookStoreConformance(InMemoryBookStore())
    }

    @Test func highlightStoreConforms() async throws {
        try await assertHighlightStoreConformance(InMemoryHighlightStore())
    }

    @Test func bookmarkStoreConforms() async throws {
        try await assertBookmarkStoreConformance(InMemoryBookmarkStore())
    }

    @Test func positionStoreConforms() async throws {
        try await assertPositionStoreConformance(InMemoryPositionStore())
    }

    @Test func conversationStoreConforms() async throws {
        try await assertConversationStoreConformance(InMemoryConversationStore())
    }

    @Test func messageStoreConforms() async throws {
        try await assertMessageStoreConformance(InMemoryMessageStore())
    }
}
