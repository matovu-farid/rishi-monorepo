import Testing
import Foundation
@testable import RishiChat
import RishiCore
import RishiTesting

/// Behavioral contract for ``ConversationsListViewModel``.
///
/// Exercised against in-memory stores (`InMemoryConversationStore` /
/// `InMemoryMessageStore` from RishiTesting) so the test stays at the logic
/// level — no GRDB, no SwiftUI, no network. Suite is `@MainActor` because the
/// viewmodel is `@MainActor`-isolated.
@MainActor
@Suite("ConversationsListViewModel", .serialized)
struct ConversationsListViewModelTests {

    // MARK: - 1. load(userId:) populates conversations in updatedAt-desc order.

    @Test("load populates conversations sorted by updatedAt desc")
    func loadSortsByUpdatedAtDesc() async {
        let userId = UUID()
        let older = Conversation(
            userId: userId,
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let newer = Conversation(
            userId: userId,
            title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let middle = Conversation(
            userId: userId,
            title: "Middle",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let convoStore = InMemoryConversationStore(initial: [older, newer, middle])
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.conversations.map { $0.title } == ["Newer", "Middle", "Older"])
        #expect(vm.loadError == nil)
    }

    // MARK: - 2. load(userId:) hydrates messagesByConversation index.

    @Test("load hydrates messagesByConversation for every conversation")
    func loadHydratesMessagesIndex() async {
        let userId = UUID()
        let c1 = Conversation(userId: userId, title: "C1", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let c2 = Conversation(userId: userId, title: "C2", updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let m1 = Message(conversationId: c1.id, role: .user, content: "Hi in c1")
        let m2 = Message(conversationId: c2.id, role: .user, content: "Hi in c2")
        let m3 = Message(conversationId: c2.id, role: .assistant, content: "Hello back")
        let convoStore = InMemoryConversationStore(initial: [c1, c2])
        let msgStore = InMemoryMessageStore(initial: [m1, m2, m3])
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.messagesByConversation[c1.id]?.count == 1)
        #expect(vm.messagesByConversation[c2.id]?.count == 2)
    }

    // MARK: - 3. Title-match search narrows filteredConversations.

    @Test("searchQuery matching title narrows filteredConversations")
    func searchByTitle() async {
        let userId = UUID()
        let c1 = Conversation(userId: userId, title: "Philosophy talks", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let c2 = Conversation(userId: userId, title: "Mystery thread",   updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let convoStore = InMemoryConversationStore(initial: [c1, c2])
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        vm.searchQuery = "mystery"
        #expect(vm.filteredConversations.count == 1)
        #expect(vm.filteredConversations.first?.title == "Mystery thread")
    }

    // MARK: - 4. Message-content search surfaces the parent conversation.

    @Test("searchQuery matching message content surfaces the parent conversation")
    func searchByMessageContent() async {
        let userId = UUID()
        let c1 = Conversation(userId: userId, title: "Random thoughts", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let c2 = Conversation(userId: userId, title: "Other",           updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let m1 = Message(conversationId: c1.id, role: .user, content: "What is transcendence?")
        let convoStore = InMemoryConversationStore(initial: [c1, c2])
        let msgStore = InMemoryMessageStore(initial: [m1])
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        vm.searchQuery = "transcendence"
        #expect(vm.filteredConversations.count == 1)
        #expect(vm.filteredConversations.first?.id == c1.id)
    }

    // MARK: - 5. delete(id:) cascades — conversation gone AND every message gone.

    @Test("delete cascades to MessageStore: child messages are removed")
    func deleteCascadesToMessages() async {
        let userId = UUID()
        let convo = Conversation(userId: userId, title: "Doomed", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let m1 = Message(conversationId: convo.id, role: .user, content: "one")
        let m2 = Message(conversationId: convo.id, role: .assistant, content: "two")
        let convoStore = InMemoryConversationStore(initial: [convo])
        let msgStore = InMemoryMessageStore(initial: [m1, m2])
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.conversations.count == 1)
        await vm.delete(id: convo.id)

        // VM state.
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation[convo.id] == nil)
        // Filtered view (no search) also empty.
        #expect(vm.filteredConversations.isEmpty)
        // Store-level cascade: no orphan messages.
        let surviving = try? await msgStore.messages(for: convo.id)
        #expect(surviving?.isEmpty == true)
        // Conversation deleted from store too.
        let stillThere = try? await convoStore.conversation(convo.id)
        #expect(stillThere == nil)
    }

    // MARK: - 6. Load error: throwing store → loadError surfaced + conversations empty.

    @Test("load failure sets loadError and leaves conversations empty")
    func loadFailureSurfacesError() async {
        let throwingStore = ThrowingConversationStore()
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: throwingStore,
            messageStore: msgStore
        )

        await vm.load(userId: UUID())
        #expect(vm.loadError != nil)
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation.isEmpty)
    }
}

// MARK: - Fakes

private enum FakeError: Error, Equatable { case boom }

/// Throws on every `conversations(for:)` call so the VM's load-error path is
/// reachable without GRDB.
private final class ThrowingConversationStore: ConversationStore, @unchecked Sendable {
    func conversations(for userId: UserID) async throws -> [Conversation] {
        throw FakeError.boom
    }
    func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
    func upsert(_ conversation: Conversation) async throws {}
    func delete(_ id: ConversationID) async throws {}
}
