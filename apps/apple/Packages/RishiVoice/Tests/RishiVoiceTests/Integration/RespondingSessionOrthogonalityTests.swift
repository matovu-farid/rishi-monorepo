import Testing
import Foundation
@testable import RishiVoice
import RishiSearch
import RishiTesting
import RishiCore

/// Phase 25-12 orthogonality guard.
///
/// Mirrors Phase 24's `Phase24PrewarmOrthogonalityTests` pattern: prove that
/// Plan 25's additions (BookContextResponder + tool-call stream) compose
/// cleanly with the pre-existing Phase 10-04 transcript pipeline
/// (VoiceTranscriptBridge + MessageStore writes) — neither pump interferes
/// with the other, and cancellation cleanly halts both.
///
/// Scenarios:
///
///   1. Both pumps spawned against the same FakeRealtimeClient. One tool-call
///      event fires the Responder + writes a tool result; ZERO message
///      upserts. One transcript final event fires the Bridge + writes a
///      message; sendToolResults count is unchanged (still 1 from step 1).
///
///   2. Cancel both tasks (simulating session.end()). Inject one more of
///      each event kind. Wait 200 ms. Assert no new sendToolResults AND no
///      new message upserts — late events are no-ops after cancellation.
@MainActor
@Suite("Responder + transcript orthogonality (Phase 25-12)", .serialized)
struct RespondingSessionOrthogonalityTests {

    @Test
    func transcriptAndToolCallDoNotCrosstalk() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")

        let bookId = UUID()
        let conversationId = UUID()
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "alpha", page: 1, score: 0.9)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: bookId)

        let messageStore = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: messageStore)
        let voiceState = VoiceSessionState()

        let respTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        let txTask = Task {
            await bridge.consume(
                stream: fake.transcriptStream(),
                conversationId: conversationId,
                state: voiceState
            )
        }
        defer {
            respTask.cancel()
            txTask.cancel()
        }

        // 1. Inject ONE tool-call event. Only the Responder pump should react.
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c1",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"alpha\"}"
        ))
        try await waitForCondition(timeoutSeconds: 2.0) {
            !fake.sentToolResultsSnapshot().isEmpty
        }
        #expect(fake.sentToolResultsSnapshot().count == 1)
        // Bridge pump must NOT have written anything from a tool-call event.
        let messagesAfterToolCall = try await messageStore.messages(for: conversationId)
        #expect(messagesAfterToolCall.isEmpty,
                "transcript bridge should not react to a tool-call event")

        // 2. Inject ONE transcript event with isFinal=true. Only the Bridge
        //    pump should react. Tool-call count must stay unchanged.
        fake.inject(transcript: RealtimeTranscriptEvent(
            role: .user, content: "hello world", isFinal: true
        ))
        try await waitForCondition(timeoutSeconds: 2.0) {
            let current = (try? await messageStore.messages(for: conversationId)) ?? []
            return !current.isEmpty
        }
        let messagesAfterTranscript = try await messageStore.messages(for: conversationId)
        #expect(messagesAfterTranscript.count == 1)
        #expect(messagesAfterTranscript.first?.content == "hello world")
        // Responder count must be byte-identical to the post-step-1 snapshot.
        #expect(fake.sentToolResultsSnapshot().count == 1,
                "responder pump should not react to a transcript event")
    }

    @Test
    func endCancelsBoth() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")

        let bookId = UUID()
        let conversationId = UUID()
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "x", page: 1, score: 0.5)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: bookId)
        let messageStore = InMemoryMessageStore()
        let bridge = VoiceTranscriptBridge(messageStore: messageStore)
        let voiceState = VoiceSessionState()

        let respTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        let txTask = Task {
            await bridge.consume(
                stream: fake.transcriptStream(),
                conversationId: conversationId,
                state: voiceState
            )
        }

        // Simulate session.end() — cancel both before any events fire.
        respTask.cancel()
        txTask.cancel()

        // Inject ONE late event of each kind. Both consumers must be inert.
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-late",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        fake.inject(transcript: RealtimeTranscriptEvent(
            role: .user, content: "late hello", isFinal: true
        ))
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms settle

        #expect(fake.sentToolResultsSnapshot().isEmpty,
                "no tool result should land after cancellation")
        let late = try await messageStore.messages(for: conversationId)
        #expect(late.isEmpty,
                "no message should be upserted after cancellation")
    }

    // MARK: - Helpers

    /// Poll `check` every 20 ms until it returns true or the timeout elapses.
    private func waitForCondition(
        timeoutSeconds: Double,
        _ check: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while await !check() {
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }
}
