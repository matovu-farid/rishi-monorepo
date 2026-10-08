import SwiftUI








struct ConversationsListHost: View {
    let userId: UserID
    let onSelect: (Conversation) -> Void

    @Environment(\.services) private var servicesEnv

    @State private var vm: ConversationsListViewModel
    @State private var activationID: UUID?

    init(
        vm: ConversationsListViewModel,
        userId: UserID,
        onSelect: @escaping (Conversation) -> Void
    ) {
        self.userId = userId
        self.onSelect = onSelect
        _vm = State(initialValue: vm)
    }

    var body: some View {
        ConversationsListView(
            viewModel: vm,
            userId: userId,
            onSelect: onSelect
        )
        .navigationTitle("Conversations")
        
        
        
        
        
        .onAppear {
            activationID = servicesEnv?.sync.chatRefreshAdapter.setActive(viewModel: vm, userId: userId)
        }
        .onDisappear {
            if let activationID {
                servicesEnv?.sync.chatRefreshAdapter.clearActive(ifActivation: activationID)
            }
            activationID = nil
        }
    }
}








struct ConversationChatHost: View {
    @State private var vm: ChatPanelViewModel

    init(vm: ChatPanelViewModel) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        NavigationStack {
            ChatPanelView(viewModel: vm, initialQuote: nil)
                .id(ObjectIdentifier(vm))
        }
    }
}
