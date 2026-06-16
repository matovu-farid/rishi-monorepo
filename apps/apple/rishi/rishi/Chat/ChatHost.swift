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
        vm: ConversationsListViewModel,
        services: BootstrappedServices,
        userId: UserID,
        onSelect: @escaping (Conversation) -> Void
    ) {
        self.userId = userId
        self.onSelect = onSelect
        self.chatRefreshAdapter = services.chatRefreshAdapter
        _vm = State(initialValue: vm)
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

/// Host view for the conversations-list tap path. Owns the
/// ``ChatPanelViewModel`` lifetime, constructing it synchronously from the
/// already-resolved ``Conversation``.
///
/// Text-only browse surface: voice is now the primary AI surface (launched
/// from the reader toolbar), so the conversation detail renders
/// ``ChatPanelView`` directly with no embedded voice affordance.
struct ConversationChatHost: View {
    @State private var vm: ChatPanelViewModel

    init(vm: ChatPanelViewModel) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        NavigationStack {
            ChatPanelView(viewModel: vm, initialQuote: nil)
        }
    }
}
