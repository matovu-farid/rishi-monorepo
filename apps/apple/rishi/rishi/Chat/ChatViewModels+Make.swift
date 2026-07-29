


extension ConversationsListViewModel {
    @MainActor
    static func make(
        conversationStore: ConversationStore,
        messageStore: MessageStore
    ) -> ConversationsListViewModel {
        ConversationsListViewModel(
            conversationStore: conversationStore,
            messageStore: messageStore
        )
    }
}

extension ChatPanelViewModel {
    @MainActor
    static func make(
        conversation: Conversation,
        chatService: any ChatService,
        messageStore: any MessageStore
    ) -> ChatPanelViewModel {
        ChatPanelViewModel(
            conversation: conversation,
            bookId: conversation.bookId,
            chatService: chatService,
            messageStore: messageStore
        )
    }
}
