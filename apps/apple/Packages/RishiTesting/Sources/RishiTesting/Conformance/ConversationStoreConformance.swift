import Foundation
import RishiCore

public func assertConversationStoreConformance(_ store: any ConversationStore) async throws {
    let userA = UUID()
    let userB = UUID()

    let empty = try await store.conversations(for: userA)
    guard empty.isEmpty else {
        throw RishiTestingError.expected("conversations initially empty")
    }

    let c1 = Conversation.fixture(userId: userA, title: "Alpha")
    try await store.upsert(c1)
    let got = try await store.conversation(c1.id)
    guard got == c1 else {
        throw RishiTestingError.expected("conversation round-trip failed")
    }

    try await store.upsert(c1)
    let aOnly = try await store.conversations(for: userA)
    guard aOnly.count == 1 else {
        throw RishiTestingError.expected("re-upsert produced \(aOnly.count) rows")
    }

    let c2 = Conversation.fixture(userId: userB, title: "Beta")
    try await store.upsert(c2)
    let bOnly = try await store.conversations(for: userB)
    guard bOnly.count == 1 else {
        throw RishiTestingError.expected("conversation scoping failed")
    }

    try await store.delete(c1.id)
    let postDelete = try await store.conversation(c1.id)
    guard postDelete == nil else {
        throw RishiTestingError.expected("conversation not deleted")
    }
}
