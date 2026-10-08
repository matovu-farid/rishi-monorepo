import Foundation
import Observation

/// Owns one panel's transcript loads and chat turns on the UI actor.
@MainActor
@Observable
public final class ChatPanelViewModel {
    public let conversation: Conversation
    public let bookId: BookID?
    public private(set) var messages: [Message] = []
    public let streamingState: ChatStreamingState
    public private(set) var isLoadingHistory = false
    public private(set) var historyError: Error?
    public private(set) var successfulTurnRevision: UInt64 = 0
    public private(set) var committedRawDraft: String?

    private let chatService: any ChatService
    private let messageStore: any MessageStore
    private var historyLoadID: UUID?
    private var activeTurnID: UUID?
    // Retained until the task drains so cancellation callers can join it.
    var activeTaskHandle: Task<Void, Never>?

    public init(
        conversation: Conversation,
        bookId: BookID?,
        chatService: any ChatService,
        messageStore: any MessageStore,
        streamingState: ChatStreamingState = ChatStreamingState()
    ) {
        self.conversation = conversation
        self.bookId = bookId
        self.chatService = chatService
        self.messageStore = messageStore
        self.streamingState = streamingState
    }

    public func loadHistory() async {
        await loadHistory(turnID: nil, allowsCancellation: false)
    }

    private func loadHistory(turnID: UUID?, allowsCancellation: Bool) async {
        guard turnID == nil || activeTurnID == turnID else { return }
        guard allowsCancellation || !Task.isCancelled else { return }
        let loadID = UUID()
        historyLoadID = loadID
        isLoadingHistory = true
        historyError = nil
        defer {
            if historyLoadID == loadID { isLoadingHistory = false }
        }
        do {
            let fetched = try await messageStore.messages(for: conversation.id)
            guard historyLoadID == loadID,
                  turnID == nil || activeTurnID == turnID,
                  allowsCancellation || !Task.isCancelled else { return }
            messages = fetched
        } catch {
            guard historyLoadID == loadID,
                  turnID == nil || activeTurnID == turnID,
                  allowsCancellation || !Task.isCancelled else { return }
            historyError = error
            Log.event("chat.history.load.failed", level: .error, data: ["error": "\(error)"])
        }
    }

    /// Clears only the submitted draft whose turn committed, preserving edits.
    public func draftAfterCommittedTurn(_ currentDraft: String) -> String {
        committedRawDraft == currentDraft ? "" : currentDraft
    }

    public func send(query rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        activeTaskHandle?.cancel()
        let turnID = UUID()
        activeTurnID = turnID
        // A previous turn/history refresh cannot publish over this turn.
        historyLoadID = nil
        isLoadingHistory = false
        committedRawDraft = nil
        streamingState.beginStreaming()
        let service = chatService
        let bookId = self.bookId
        activeTaskHandle = Task { [weak self] in
            guard let self, self.activeTurnID == turnID else { return }
            defer {
                if self.activeTurnID == turnID {
                    self.streamingState.endStreaming()
                    self.activeTurnID = nil
                    self.activeTaskHandle = nil
                }
            }
            do {
                for try await event in service.stream(query: query, bookId: bookId) {
                    guard self.activeTurnID == turnID else { return }
                    try Task.checkCancellation()
                    switch event {
                    case .token(let token): self.streamingState.appendToken(token)
                    case .toolCall: continue
                    case .completed:
                        // ChatService emits completion only after the assistant commit.
                        self.committedRawDraft = rawQuery
                        self.successfulTurnRevision &+= 1
                        await self.loadHistory(turnID: turnID, allowsCancellation: false)
                        return
                    }
                }
                // A canceled stream may finish normally; it has no committed-success marker.
                await self.loadHistory(turnID: turnID, allowsCancellation: true)
            } catch is CancellationError {
                await self.loadHistory(turnID: turnID, allowsCancellation: true)
            } catch {
                guard self.activeTurnID == turnID, !Task.isCancelled else { return }
                self.streamingState.failStreaming(error)
                await self.loadHistory(turnID: turnID, allowsCancellation: false)
            }
        }
    }

    public func cancel() {
        activeTaskHandle?.cancel()
        // Explicit history loads may outlive the presentation too.
        historyLoadID = nil
        isLoadingHistory = false
    }
}
