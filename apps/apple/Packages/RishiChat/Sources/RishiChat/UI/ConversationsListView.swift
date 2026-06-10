import SwiftUI
import RishiCore
import RishiUIKit

/// Top-level Conversations tab (CHAT-06).
///
/// Renders the user's conversations as a swipe-to-delete list with a
/// `.searchable` binding that drives ``ConversationsListViewModel/searchQuery``
/// (filter applied via ``ConversationSearchFilter``). Empty state (CHAT-07)
/// shows when the user has zero conversations AND has not typed a query.
///
/// Selection is delegated upward via `onSelect` so the app layer (Plan 09-06)
/// owns the routing decision (push a ``ChatPanelView`` for the chosen row).
///
/// All visuals route through RishiUIKit tokens — no hardcoded colors, no
/// hex literals, no `.system(size:)` / integer-padding literals.
public struct ConversationsListView: View {

    @Bindable private var viewModel: ConversationsListViewModel
    private let userId: UserID
    private let onSelect: (Conversation) -> Void

    @State private var pendingDelete: Conversation? = nil

    public init(
        viewModel: ConversationsListViewModel,
        userId: UserID,
        onSelect: @escaping (Conversation) -> Void
    ) {
        self._viewModel = Bindable(wrappedValue: viewModel)
        self.userId = userId
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            if viewModel.conversations.isEmpty && viewModel.searchQuery.isEmpty {
                ConversationsEmptyState()
            } else {
                List {
                    ForEach(viewModel.filteredConversations) { convo in
                        Button {
                            onSelect(convo)
                        } label: {
                            ConversationRow(conversation: convo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("conversations.row.\(convo.id.uuidString)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = convo
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("conversations.row.delete")
                            .accessibilityLabel(A11yLabel.conversationDelete)
                        }
                    }
                }
                .listStyle(.plain)
                .background(RishiColor.background)
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search conversations")
        .navigationTitle("Conversations")
        .task {
            await viewModel.load(userId: userId)
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { convo in
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.delete(id: convo.id)
                    pendingDelete = nil
                }
            }
            .accessibilityIdentifier("conversations.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Messages will be removed from this device and from sync.")
        }
    }
}

// MARK: - Previews

private struct PreviewConversationsStore: ConversationStore {
    let seeded: [Conversation]
    func conversations(for userId: UserID) async throws -> [Conversation] { seeded }
    func conversation(_ id: ConversationID) async throws -> Conversation? {
        seeded.first(where: { $0.id == id })
    }
    func upsert(_ conversation: Conversation) async throws {}
    func delete(_ id: ConversationID) async throws {}
}

private struct PreviewConversationsMessageStore: MessageStore {
    let seeded: [ConversationID: [Message]]
    func messages(for conversationId: ConversationID) async throws -> [Message] {
        seeded[conversationId] ?? []
    }
    func upsert(_ message: Message) async throws {}
    func delete(_ id: MessageID) async throws {}
}

@MainActor
private enum ConversationsListPreviewFixtures {
    static let userId: UserID = UUID()

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 60 * 60 * 24

    static func populated() -> (ConversationsListViewModel, [Conversation]) {
        let convoA = Conversation(
            userId: userId,
            bookId: UUID(),
            title: "Why does the protagonist hesitate at the bridge?",
            createdAt: Date().addingTimeInterval(-hour * 6),
            updatedAt: Date().addingTimeInterval(-minute * 4)
        )
        let convoB = Conversation(
            userId: userId,
            bookId: UUID(),
            title: "Symbolism of the river in chapter three",
            createdAt: Date().addingTimeInterval(-day),
            updatedAt: Date().addingTimeInterval(-hour)
        )
        let convoC = Conversation(
            userId: userId,
            bookId: nil,
            title: "Reading goals for the quarter",
            createdAt: Date().addingTimeInterval(-day * 3),
            updatedAt: Date().addingTimeInterval(-day)
        )
        let convoD = Conversation(
            userId: userId,
            bookId: UUID(),
            title: "Summarize chapter twelve in two sentences",
            createdAt: Date().addingTimeInterval(-day * 5),
            updatedAt: Date().addingTimeInterval(-day * 2)
        )

        let conversations = [convoA, convoB, convoC, convoD]
        let messages: [ConversationID: [Message]] = [
            convoA.id: [
                Message(conversationId: convoA.id, role: .user, content: "Why does she hesitate at the bridge?"),
                Message(conversationId: convoA.id, role: .assistant, content: "Because the bridge is where she last saw her grandfather."),
            ],
            convoB.id: [
                Message(conversationId: convoB.id, role: .user, content: "What does the river symbolize here?"),
                Message(conversationId: convoB.id, role: .assistant, content: "Inherited memory — the prose echoes phrases used to describe the grandfather."),
            ],
            convoC.id: [
                Message(conversationId: convoC.id, role: .user, content: "Help me set reading goals for this quarter."),
            ],
        ]

        let vm = ConversationsListViewModel(
            conversationStore: PreviewConversationsStore(seeded: conversations),
            messageStore: PreviewConversationsMessageStore(seeded: messages)
        )
        return (vm, conversations)
    }

    static func empty() -> ConversationsListViewModel {
        ConversationsListViewModel(
            conversationStore: PreviewConversationsStore(seeded: []),
            messageStore: PreviewConversationsMessageStore(seeded: [:])
        )
    }

    static func populatedWithSearch(_ query: String) -> ConversationsListViewModel {
        let (vm, _) = populated()
        vm.searchQuery = query
        return vm
    }
}

#Preview("List - empty") {
    NavigationStack {
        ConversationsListView(
            viewModel: ConversationsListPreviewFixtures.empty(),
            userId: ConversationsListPreviewFixtures.userId,
            onSelect: { _ in }
        )
    }
}

#Preview("List - populated") {
    NavigationStack {
        ConversationsListView(
            viewModel: ConversationsListPreviewFixtures.populated().0,
            userId: ConversationsListPreviewFixtures.userId,
            onSelect: { _ in }
        )
    }
}

#Preview("List - search active") {
    NavigationStack {
        ConversationsListView(
            viewModel: ConversationsListPreviewFixtures.populatedWithSearch("river"),
            userId: ConversationsListPreviewFixtures.userId,
            onSelect: { _ in }
        )
    }
}

#Preview("List - dark") {
    NavigationStack {
        ConversationsListView(
            viewModel: ConversationsListPreviewFixtures.populated().0,
            userId: ConversationsListPreviewFixtures.userId,
            onSelect: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
