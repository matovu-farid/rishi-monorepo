@testable import rishi
import Testing
import Foundation




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
        // Final must remain visible in live UI (not cleared on isFinal).
        #expect(state.partialAssistantTranscript == "Hello!")
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
        // User final also stays visible until the next user utterance.
        #expect(state.partialUserTranscript == "Hi")
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

    @Test("Partials plus empty final flush keep full text visible")
    func emptyFinalFlushKeepsVisibleTranscript() async throws {
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
        continuation.yield(.init(role: .assistant, content: "a time", isFinal: false))
        // Pump flush pattern: empty content + isFinal after deltas.
        continuation.yield(.init(role: .assistant, content: "", isFinal: true))
        continuation.finish()
        await task.value

        let messages = try await store.messages(for: conversationId)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Once upon a time")
        #expect(state.partialAssistantTranscript == "Once upon a time")
    }

    @Test("Next non-empty partial for a role clears held final then shows new text")
    func nextPartialReplacesHeldFinal() async throws {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .assistant, content: "First turn", isFinal: false))
        continuation.yield(.init(role: .assistant, content: "", isFinal: true))
        continuation.yield(.init(role: .assistant, content: "Second", isFinal: false))
        continuation.finish()
        await task.value

        let messages = try await store.messages(for: conversationId)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "First turn")
        #expect(state.partialAssistantTranscript == "Second")
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

    @Test("assistant partial sets activityPhase speaking")
    func assistantPartialSetsSpeaking() async {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .assistant, content: "Hel", isFinal: false))
        continuation.finish()
        await task.value

        #expect(state.activityPhase == .speaking)
    }

    @Test("assistant final sets activityPhase listening")
    func assistantFinalSetsListening() async {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .assistant, content: "Done", isFinal: true))
        continuation.finish()
        await task.value

        #expect(state.activityPhase == .listening)
    }

    @Test("user partial sets activityPhase listening")
    func userPartialSetsListening() async {
        let conversationId = UUID()
        let store = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: store)
        let state = VoiceSessionState()
        let (stream, continuation) = AsyncStream<RealtimeTranscriptEvent>.makeStream()

        let task = Task {
            await bridge.consume(stream: stream, conversationId: conversationId, state: state)
        }
        continuation.yield(.init(role: .user, content: "Hi", isFinal: false))
        continuation.finish()
        await task.value

        #expect(state.activityPhase == .listening)
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
