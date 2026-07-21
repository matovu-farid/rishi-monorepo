import Testing
import Foundation
@testable import RishiVoice
import RishiCore
import RishiTesting

@MainActor
@Suite("VoiceTranscriptBridge", .serialized)
struct VoiceTranscriptBridgeTests {

    @Test("Final assistant fragment persists a Message with accumulated content")
    func finalAssistantPersists() async throws {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let hook = RecordingDirtyHook()
        let bridge = VoiceTranscriptBridge(messageStore: store, dirtyHook: hook)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }

        continuation.yield(.init(role: .assistant, content: "Hel", isFinal: false))
        continuation.yield(.init(role: .assistant, content: "lo", isFinal: false))
        continuation.yield(.init(role: .assistant, content: "!", isFinal: true))
        continuation.finish()
        await task.value

        let messages = try await store.messages(for: conversationId)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello!")
        #expect(messages.first?.role == .assistant)
        #expect(messages.first?.conversationId == conversationId)
        #expect(hook.messageUpdates.count == 1)
        #expect(hook.conversationUpdates == [conversationId])
    }

    @Test("Final user fragment persists independently of assistant buffer")
    func finalUserDoesNotFlushAssistantBuffer() async throws {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }

        continuation.yield(.init(role: .assistant, content: "draft", isFinal: false))
        continuation.yield(.init(role: .user, content: "Hi", isFinal: true))
        continuation.finish()
        await task.value

        let messages = try await store.messages(for: conversationId)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
        #expect(messages.first?.content == "Hi")
        // The assistant buffer is preserved in the live state.
        #expect(state.partialAssistantTranscript == "draft")
    }

    @Test("Empty isFinal event does not persist")
    func emptyFinalDoesNotPersist() async throws {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .assistant, content: "", isFinal: true))
        continuation.finish()
        await task.value

        let messages = try await store.messages(for: conversationId)
        #expect(messages.isEmpty)
    }

    @Test("Partial fragments update VoiceSessionState live")
    func partialsUpdateState() async {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .assistant, content: "Once ", isFinal: false))
        continuation.yield(.init(role: .assistant, content: "upon ", isFinal: false))
        continuation.finish()
        await task.value

        #expect(state.partialAssistantTranscript == "Once upon ")
    }

    @Test("onActivity fires for user and assistant events (partial and final)")
    func onActivityFiresForBothRoles() async {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let counter = ActivityCounter()
        let bridge = VoiceTranscriptBridge(
            messageStore: store,
            onActivity: { await counter.increment() }
        )
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .user, content: "Hi", isFinal: false))
        continuation.yield(.init(role: .user, content: "!", isFinal: true))
        continuation.yield(.init(role: .assistant, content: "Hello", isFinal: true))
        continuation.finish()
        await task.value

        #expect(await counter.count == 3)
    }

    // MARK: - Helpers

    actor ActivityCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    final class RecordingDirtyHook: VoiceTranscriptDirtyHook, @unchecked Sendable {
        private let lock = NSLock()
        private var _conversationUpdates: [ConversationID] = []
        private var _messageUpdates: [MessageID] = []
        var conversationUpdates: [ConversationID] { lock.withLock { _conversationUpdates } }
        var messageUpdates: [MessageID] { lock.withLock { _messageUpdates } }
        func conversationDidUpdate(_ id: ConversationID) async {
            lock.withLock { _conversationUpdates.append(id) }
        }
        func messageDidUpdate(_ id: MessageID) async {
            lock.withLock { _messageUpdates.append(id) }
        }
    }
}
