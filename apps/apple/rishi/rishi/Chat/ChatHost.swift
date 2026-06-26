import SwiftUI
import RishiChat
import RishiCore






struct ConversationsListHost: View {
    let userId: UserID
    let onSelect: (Conversation) -> Void

    @Environment(\.services) private var servicesEnv

    @State private var vm: ConversationsListViewModel

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
        
        
        
        
        
        .task {
            servicesEnv?.chatRefreshAdapter.setActive(viewModel: vm, userId: userId)
        }
        .onDisappear {
            servicesEnv?.chatRefreshAdapter.clearActive()
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
        }
    }
}
