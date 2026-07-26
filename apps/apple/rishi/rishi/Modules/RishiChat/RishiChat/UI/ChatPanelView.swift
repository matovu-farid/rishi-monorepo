import SwiftUI



/// SwiftUI sheet presented from the reader (Phase 9-06 wires that).
///
/// Owns a ``ChatPanelViewModel`` constructed at the app layer with the
/// resolved ``Conversation`` for the active `(userId, bookId)` pair. Renders
/// the persisted transcript plus a transient "ghost" assistant bubble while a
/// turn is in flight, and a composer with a send / cancel button toggle
/// driven by ``ChatStreamingState.isStreaming``.
///
/// All visuals route through RishiUIKit tokens — no hardcoded colors, no
/// integer `.padding(N)`, no `.system(size:)` literals.
public struct ChatPanelView: View {

    @Bindable private var viewModel: ChatPanelViewModel
    @State private var inputText: String
    @FocusState private var inputFocused: Bool

    public init(viewModel: ChatPanelViewModel, initialQuote: String? = nil) {
        self._viewModel = Bindable(wrappedValue: viewModel)
        if let q = initialQuote, !q.isEmpty {
            self._inputText = State(initialValue: "> \(q)\n\n")
        } else {
            self._inputText = State(initialValue: "")
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .background(RishiColor.background)
        .task {
            await viewModel.loadHistory()
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RishiSpacing.s) {
                    ForEach(viewModel.messages) { message in
                        ChatMessageBubble(message: message)
                            .id(message.id)
                    }
                    if let streaming = viewModel.streamingState.streamingMessage {
                        ChatMessageBubble(
                            message: Message(
                                conversationId: viewModel.conversation.id,
                                role: .assistant,
                                content: streaming
                            )
                        )
                        .id(Self.streamingRowID)
                    }
                }
                .padding(RishiSpacing.m)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.streamingState.streamingMessage) { _, newValue in
                if newValue != nil {
                    withAnimation { proxy.scrollTo(Self.streamingRowID, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: RishiSpacing.s) {
            TextField("Ask about this book…", text: $inputText, axis: .vertical)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .lineLimit(1...4)
                .accessibilityIdentifier("chat.input")
                .accessibilityLabel(A11yLabel.chatMessageInput)

            if viewModel.streamingState.isStreaming {
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(RishiColor.danger)
                }
                .accessibilityIdentifier("chat.cancel")
                .accessibilityLabel(A11yLabel.chatCancelStreaming)
            } else {
                Button {
                    let toSend = inputText
                    inputText = ""
                    viewModel.send(query: toSend)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(RishiColor.accent)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat.send")
                .accessibilityLabel(A11yLabel.chatSendMessage)
            }
        }
        .padding(RishiSpacing.m)
        .background(RishiColor.surface)
    }

    private static let streamingRowID = "chat.streaming.ghost"
}

// MARK: - Previews

private struct PreviewMessageStore: MessageStore {
    let seeded: [Message]
    func messages(for conversationId: ConversationID) async throws -> [Message] {
        seeded.filter { $0.conversationId == conversationId }
    }
    func message(_ id: MessageID) async throws -> Message? {
        seeded.first(where: { $0.id == id })
    }
    func upsert(_ message: Message) async throws {}
    func delete(_ id: MessageID) async throws {}
}

private struct PreviewChatService: ChatService {
    func stream(query: String, bookId: BookID?) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@MainActor
private enum ChatPanelPreviewFixtures {
    static func conversation() -> Conversation {
        Conversation(userId: UUID(), bookId: UUID(), title: "About this book")
    }

    static func emptyViewModel() -> ChatPanelViewModel {
        let convo = conversation()
        return ChatPanelViewModel(
            conversation: convo,
            bookId: convo.bookId,
            chatService: PreviewChatService(),
            messageStore: PreviewMessageStore(seeded: [])
        )
    }

    static func exchangeViewModel() -> ChatPanelViewModel {
        let convo = conversation()
        let seed: [Message] = [
            Message(conversationId: convo.id, role: .user, content: "Who is the narrator in chapter one?"),
            Message(
                conversationId: convo.id,
                role: .assistant,
                content: "The narrator is the protagonist's younger sister, speaking from the present looking back on a summer in their childhood."
            ),
            Message(conversationId: convo.id, role: .user, content: "Why does she keep returning to the river?"),
            Message(
                conversationId: convo.id,
                role: .assistant,
                content: "The river is the strongest sensory anchor she has to their grandfather — every time she returns to it the prose deliberately echoes phrases used to describe him in chapter two."
            ),
        ]
        return ChatPanelViewModel(
            conversation: convo,
            bookId: convo.bookId,
            chatService: PreviewChatService(),
            messageStore: PreviewMessageStore(seeded: seed)
        )
    }

    static func streamingViewModel() -> ChatPanelViewModel {
        let vm = exchangeViewModel()
        vm.streamingState.beginStreaming()
        vm.streamingState.appendToken("Yes — the storm in chapter four mirrors the argument in chapter one, both in ")
        vm.streamingState.appendToken("the language used and in how it ends mid-sentence with the same ")
        return vm
    }
}

#Preview("Panel - empty") {
    ChatPanelView(viewModel: ChatPanelPreviewFixtures.emptyViewModel())
}

#Preview("Panel - one exchange") {
    ChatPanelView(viewModel: ChatPanelPreviewFixtures.exchangeViewModel())
}

#Preview("Panel - mid-stream") {
    ChatPanelView(viewModel: ChatPanelPreviewFixtures.streamingViewModel())
}

#Preview("Panel - dark") {
    ChatPanelView(viewModel: ChatPanelPreviewFixtures.exchangeViewModel())
        .preferredColorScheme(.dark)
}
