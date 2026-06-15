import SwiftUI
import RishiChat
import RishiCore

/// Host view that owns the ``ConversationsListViewModel`` lifetime.
///
/// Constructing the VM here (rather than in ``AppDependencies``) keeps
/// service-only logic out of the view-model factory layer and gives SwiftUI
/// a stable `@State` anchor for the object.
struct ConversationsListHost: View {
    let userId: UserID
    let onSelect: (Conversation) -> Void
    let chatRefreshAdapter: AppChatRefreshAdapter

    @State private var vm: ConversationsListViewModel

    init(
        services: BootstrappedServices,
        userId: UserID,
        onSelect: @escaping (Conversation) -> Void
    ) {
        self.userId = userId
        self.onSelect = onSelect
        self.chatRefreshAdapter = services.chatRefreshAdapter
        _vm = State(initialValue: ConversationsListViewModel(
            conversationStore: services.conversationStore,
            messageStore: services.messageStore
        ))
    }

    var body: some View {
        ConversationsListView(
            viewModel: vm,
            userId: userId,
            onSelect: onSelect
        )
        .navigationTitle("Conversations")
        .task {
            chatRefreshAdapter.setActive(viewModel: vm, userId: userId)
        }
        .onDisappear {
            chatRefreshAdapter.clearActive()
        }
    }
}
