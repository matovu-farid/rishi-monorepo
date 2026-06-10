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
