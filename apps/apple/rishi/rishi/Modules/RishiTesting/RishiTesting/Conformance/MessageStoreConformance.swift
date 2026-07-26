import Foundation


public func assertMessageStoreConformance(_ store: any MessageStore) async throws {
    let conv = UUID()
    let otherConv = UUID()

    let empty = try await store.messages(for: conv)
    guard empty.isEmpty else {
        throw RishiTestingError.expected("messages initially empty")
    }

    let m1 = Message.fixture(conversationId: conv, role: .user, content: "hello")
    let m2 = Message.fixture(conversationId: conv, role: .assistant, content: "world",
                             createdAt: Date(timeIntervalSince1970: 1_700_000_100))
    try await store.upsert(m1)
    try await store.upsert(m2)
    let inOrder = try await store.messages(for: conv)
    guard inOrder.count == 2, inOrder.first?.id == m1.id, inOrder.last?.id == m2.id else {
        throw RishiTestingError.expected("messages out of insertion/createdAt order")
    }

    try await store.upsert(m1) // idempotent
    let stillTwo = try await store.messages(for: conv)
    guard stillTwo.count == 2 else {
        throw RishiTestingError.expected("re-upsert duplicated message")
    }

    let other = Message.fixture(conversationId: otherConv, content: "elsewhere")
    try await store.upsert(other)
    let otherList = try await store.messages(for: otherConv)
    guard otherList.count == 1 else {
        throw RishiTestingError.expected("message conversation scoping failed")
    }

    try await store.delete(m1.id)
    let postDelete = try await store.messages(for: conv)
    guard postDelete.count == 1 else {
        throw RishiTestingError.expected("message not deleted")
    }
}
