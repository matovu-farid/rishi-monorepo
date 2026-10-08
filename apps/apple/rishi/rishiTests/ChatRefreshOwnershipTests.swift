@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Chat refresh registration ownership", .serialized, .timeLimit(.minutes(1)))
struct ChatRefreshOwnershipTests {
    @Test("old queued refresh and old teardown cannot control a replacement registration")
    func replacementRegistration() async throws {
        let a = UUID(), b = UUID()
        let rowA = Conversation(userId: a, title: "A")
        let rowB = Conversation(userId: b, title: "B")
        let rows = RefreshRowsStore(rows: [rowA, rowB])
        let vmA = ConversationsListViewModel(conversationStore: rows, messageStore: InMemoryMessageStore())
        let vmB = ConversationsListViewModel(conversationStore: rows, messageStore: InMemoryMessageStore())
        let adapter = AppChatRefreshAdapter()
        let activationA = adapter.setActive(viewModel: vmA, userId: a)
        // The real queued task cannot start while this synchronous MainActor turn runs.
        let oldRefresh = try #require(adapter.enqueueRefresh())
        let activationB = adapter.setActive(viewModel: vmB, userId: b)
        adapter.clearActive(ifActivation: activationA)
        let newRefresh = try #require(adapter.enqueueRefresh())
        await oldRefresh.value
        await newRefresh.value
        #expect(await rows.readUsers == [b])
        #expect(vmA.conversations.isEmpty)
        #expect(vmB.conversations == [rowB])
        adapter.clearActive(ifActivation: activationB)
        #expect(adapter.enqueueRefresh() == nil)
    }

    @Test("clearing a matching activation fences already queued work")
    func clearedQueuedRefresh() async throws {
        let user = UUID()
        let rows = RefreshRowsStore(rows: [Conversation(userId: user, title: "row")])
        let vm = ConversationsListViewModel(conversationStore: rows, messageStore: InMemoryMessageStore())
        let adapter = AppChatRefreshAdapter()
        let activation = adapter.setActive(viewModel: vm, userId: user)
        let task = try #require(adapter.enqueueRefresh())
        adapter.clearActive(ifActivation: activation)
        await task.value
        #expect(await rows.readUsers.isEmpty)
        #expect(vm.conversations.isEmpty)
    }
}

private actor RefreshRowsStore: ConversationStore {
    private var rows: [Conversation]
    private(set) var readUsers: [UserID] = []
    init(rows: [Conversation]) { self.rows = rows }
    func conversations(for userId: UserID) async throws -> [Conversation] {
        readUsers.append(userId)
        return rows.filter { $0.userId == userId }
    }
    func conversation(_ id: ConversationID) async throws -> Conversation? { rows.first { $0.id == id } }
    func upsert(_ conversation: Conversation) async throws { rows.removeAll { $0.id == conversation.id }; rows.append(conversation) }
    func delete(_ id: ConversationID) async throws { rows.removeAll { $0.id == id } }
}
