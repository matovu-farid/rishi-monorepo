


extension ConversationsListViewModel {
    @MainActor
    static func make(services: BootstrappedServices) -> ConversationsListViewModel {
        ConversationsListViewModel(conversationStore: services.chat.conversationStore,
                                   messageStore: services.chat.messageStore)
    }
}

extension ChatPanelViewModel {
    @MainActor
    static func make(conversation: Conversation, services: BootstrappedServices) -> ChatPanelViewModel {
        ChatPanelViewModel(conversation: conversation, bookId: conversation.bookId,
                           chatService: services.chat.service, messageStore: services.chat.messageStore)
    }
}
