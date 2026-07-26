


extension ConversationsListViewModel {
    @MainActor
    static func make(services: BootstrappedServices) -> ConversationsListViewModel {
        ConversationsListViewModel(conversationStore: services.conversationStore,
                                   messageStore: services.messageStore)
    }
}

extension ChatPanelViewModel {
    @MainActor
    static func make(conversation: Conversation, services: BootstrappedServices) -> ChatPanelViewModel {
        ChatPanelViewModel(conversation: conversation, bookId: conversation.bookId,
                           chatService: services.chatService, messageStore: services.messageStore)
    }
}
