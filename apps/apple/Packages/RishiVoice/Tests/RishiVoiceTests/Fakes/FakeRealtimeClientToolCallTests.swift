import Testing
import Foundation
@testable import RishiVoice

/// Tests for the tool-call surface added to `FakeRealtimeClient` in Plan 25-07.
/// Mirrors the existing transcript injection pattern, plus adds the first
/// write-back surface (`sendToolResult`) used by Plan 25-09's BookContextResponder.
///
/// Out of scope for these tests:
/// - Round-tripping against the real `swift-realtime-openai` SDK (covered by
///   Plan 25-12 integration tests).
@Suite("FakeRealtimeClient tool-call surface")
struct FakeRealtimeClientToolCallTests {

    // MARK: - inject(toolCall:) — replay-before-subscribe semantics

    @Test("inject(toolCall:) before subscribing → events replay on subscribe")
    func injectBeforeSubscribeReplays() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        // Inject TWO events BEFORE anyone calls toolCallStream().
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c1", name: "bookContext", argumentsJSON: "{\"queryText\":\"a\"}"
        ))
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c2", name: "bookContext", argumentsJSON: "{\"queryText\":\"b\"}"
        ))

        // Now subscribe — both events should replay in order.
        var iter = fake.toolCallStream().makeAsyncIterator()
        let first = await iter.next()
        let second = await iter.next()
        #expect(first?.callId == "c1")
        #expect(first?.argumentsJSON == "{\"queryText\":\"a\"}")
        #expect(second?.callId == "c2")
        #expect(second?.argumentsJSON == "{\"queryText\":\"b\"}")
    }

    @Test("inject(toolCall:) after subscribing → events arrive in order")
    func injectAfterSubscribeArrivesInOrder() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        var iter = fake.toolCallStream().makeAsyncIterator()

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c1", name: "bookContext", argumentsJSON: "{}"
        ))
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c2", name: "bookContext", argumentsJSON: "{}"
        ))

        let first = await iter.next()
        let second = await iter.next()
        #expect(first?.callId == "c1")
        #expect(second?.callId == "c2")
    }

    // MARK: - sendToolResult — recording + error staging

    @Test("sendToolResult while connected records (callId, payload) in snapshot")
    func sendToolResultRecordsInSnapshot() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        try await fake.sendToolResult(callId: "c1", payload: "[]")
        try await fake.sendToolResult(callId: "c2", payload: "[{\"text\":\"foo\"}]")

        let snapshot = fake.sentToolResultsSnapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot[0].callId == "c1")
        #expect(snapshot[0].payload == "[]")
        #expect(snapshot[1].callId == "c2")
        #expect(snapshot[1].payload == "[{\"text\":\"foo\"}]")
    }

    @Test("sendToolResult while disconnected throws not_connected")
    func sendToolResultDisconnectedThrows() async throws {
        let fake = FakeRealtimeClient()
        // NOT connected.

        await #expect(throws: RealtimeClientError.self) {
            try await fake.sendToolResult(callId: "c1", payload: "[]")
        }
        // And the call should NOT be recorded.
        #expect(fake.sentToolResultsSnapshot().isEmpty)
    }

    @Test("setSendToolResultError stages a one-shot throw; subsequent send succeeds")
    func sendToolResultErrorIsOneShot() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        let staged = RealtimeClientError(code: "send_failed", message: "boom")
        fake.setSendToolResultError(staged)

        // First call throws the staged error.
        await #expect(throws: RealtimeClientError.self) {
            try await fake.sendToolResult(callId: "c1", payload: "[]")
        }
        // Snapshot empty — the call was rejected before recording.
        #expect(fake.sentToolResultsSnapshot().isEmpty)

        // Second call succeeds and records normally — staged error was one-shot.
        try await fake.sendToolResult(callId: "c2", payload: "[]")
        let snapshot = fake.sentToolResultsSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].callId == "c2")
    }

    // MARK: - Orthogonality with transcript surface

    @Test("Existing transcript injection still works after tool-call surface added")
    func transcriptOrthogonality() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        let txStream = fake.transcriptStream()
        var txIter = txStream.makeAsyncIterator()

        fake.inject(transcript: RealtimeTranscriptEvent(
            role: .user,
            content: "hello",
            isFinal: true
        ))
        let event = await txIter.next()
        #expect(event?.content == "hello")
        #expect(event?.role == .user)
        #expect(event?.isFinal == true)
    }

    // MARK: - disconnect() finishes the tool-call stream

    @Test("disconnect() finishes the tool-call stream")
    func disconnectFinishesToolCallStream() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        let stream = fake.toolCallStream()
        await fake.disconnect()

        // After disconnect, the stream should finish — iterator yields nil.
        var iter = stream.makeAsyncIterator()
        let next = await iter.next()
        #expect(next == nil)
    }
}
