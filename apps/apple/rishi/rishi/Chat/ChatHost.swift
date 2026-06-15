import SwiftUI
import RishiChat
import RishiCore
import RishiBilling

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

/// Host view for the presenter-driven chat-panel sheet (reader chat button /
/// "Ask about this"). Owns the ``ChatPanelViewModel`` lifetime and resolves
/// (or creates) the ``Conversation`` asynchronously via
/// ``ConversationLookup``, mirroring the behavior previously in
/// ``AppDependencies/makeChatPanelViewModel(userId:bookId:)``.
///
/// Shows a ``ProgressView`` while the lookup is in flight and remains on that
/// state if the lookup throws (matching the previous nil-return behavior
/// where the sheet stayed showing a spinner). The `.task(id:)` is keyed to
/// `pending.id` so a new `Pending` value re-triggers the lookup, exactly as
/// before.
struct ChatPanelHostView: View {
    let pending: ChatPresenterImpl.Pending
    let userId: UserID
    let services: BootstrappedServices
    let onFreeUserTap: () -> Void

    @State private var vm: ChatPanelViewModel?

    var body: some View {
        Group {
            if let vm {
                NavigationStack {
                    ChatPanelHost(
                        presenter: services.voicePresenter,
                        viewModel: vm,
                        bookId: pending.bookId,
                        initialQuote: pending.initialQuote,
                        onFreeUserTap: onFreeUserTap,
                        entitlementProvider: { [services] in
                            await services.entitlementService.snapshot()
                        }
                    )
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: pending.id) {
            vm = nil
            if let convo = try? await services.conversationLookup.findOrCreate(
                userId: userId,
                bookId: pending.bookId
            ) {
                vm = ChatPanelViewModel(
                    conversation: convo,
                    bookId: pending.bookId,
                    chatService: services.chatService,
                    messageStore: services.messageStore
                )
            }
        }
    }
}

/// Host view for the conversations-list tap path. Owns the
/// ``ChatPanelViewModel`` lifetime, constructing it synchronously from the
/// already-resolved ``Conversation``.
///
/// Replaces the inline `let vm = deps.makeChatPanelViewModel(conversation:)`
/// in ``RootView``'s `.sheet(item: $selectedConversation)` closure.
struct ConversationChatHost: View {
    @State private var vm: ChatPanelViewModel
    let services: BootstrappedServices
    let onFreeUserTap: () -> Void

    init(
        conversation: Conversation,
        services: BootstrappedServices,
        onFreeUserTap: @escaping () -> Void
    ) {
        _vm = State(initialValue: ChatPanelViewModel(
            conversation: conversation,
            bookId: conversation.bookId,
            chatService: services.chatService,
            messageStore: services.messageStore
        ))
        self.services = services
        self.onFreeUserTap = onFreeUserTap
    }

    var body: some View {
        NavigationStack {
            ChatPanelHost(
                presenter: services.voicePresenter,
                viewModel: vm,
                bookId: vm.bookId,
                initialQuote: nil,
                onFreeUserTap: onFreeUserTap,
                entitlementProvider: { [services] in
                    await services.entitlementService.snapshot()
                }
            )
        }
    }
}
