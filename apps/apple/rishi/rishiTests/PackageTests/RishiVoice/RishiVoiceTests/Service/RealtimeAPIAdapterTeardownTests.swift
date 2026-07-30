@testable import rishi
import Testing
import Foundation


/// White-box tests for `RealtimeAPIAdapter.teardownActiveConversation()` — the
/// single-peer invariant that fixes the "two concurrent voices" bug.
///
/// Root cause: `connect(ephemeralKey:)` reassigned the `errorPump` /
/// `transcriptPump` / `toolCallPump` handles on RECONNECT without cancelling the
/// old ones. The orphaned pumps kept the old `Conversation` (and its WebRTC
/// peer + audio) alive, so a reconnect produced two live peers → two voices.
///
/// `teardownActiveConversation()` cancels the active pumps and releases the
/// current `Conversation` WITHOUT finishing the stream continuations, so a
/// reconnect can keep the same transcript/tool/error streams alive. It is
/// `internal` for white-box testing (mirrors `isArgumentsReady`).
@Suite("RealtimeAPIAdapter single-peer teardown")
struct RealtimeAPIAdapterTeardownTests {

    @Test("teardownActiveConversation cancels + nils all three pumps")
    func teardownNilsPumps() async {
        let adapter = RealtimeAPIAdapter()

        // Sentinel pumps that would otherwise run for 10s — stand-ins for the
        // long-lived SDK pump loops assigned in `startPumps(for:)`.
        adapter.errorPump = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        adapter.transcriptPump = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        adapter.toolCallPump = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }

        #expect(adapter.errorPump != nil)
        #expect(adapter.transcriptPump != nil)
        #expect(adapter.toolCallPump != nil)

        await adapter.teardownActiveConversation()

        #expect(adapter.errorPump == nil)
        #expect(adapter.transcriptPump == nil)
        #expect(adapter.toolCallPump == nil)
    }

    @Test("teardownActiveConversation is idempotent when nothing is active")
    func teardownIdempotent() async {
        let adapter = RealtimeAPIAdapter()
        await adapter.teardownActiveConversation()
        #expect(adapter.errorPump == nil)
        #expect(adapter.transcriptPump == nil)
        #expect(adapter.toolCallPump == nil)
    }

    @Test("concurrent pump replacement and teardown leaves no task handles")
    func concurrentPumpLifecycleIsSerialized() async {
        let adapter = RealtimeAPIAdapter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    adapter.errorPump = Task {}
                    adapter.transcriptPump = Task {}
                    adapter.toolCallPump = Task {}
                }
                group.addTask {
                    await adapter.teardownActiveConversation()
                }
            }
        }

        await adapter.teardownActiveConversation()

        #expect(adapter.errorPump == nil)
        #expect(adapter.transcriptPump == nil)
        #expect(adapter.toolCallPump == nil)
    }

    @Test("events from an old generation do not reach a reconnected stream")
    func staleEventsAreDroppedAfterTeardown() async {
        let adapter = RealtimeAPIAdapter()
        let oldGeneration = adapter.eventGeneration
        let stream = adapter.transcriptStream()
        var iterator = stream.makeAsyncIterator()

        await adapter.teardownActiveConversation()
        let currentGeneration = adapter.eventGeneration
        let stale = RealtimeTranscriptEvent(role: .assistant, content: "old", isFinal: true)
        let current = RealtimeTranscriptEvent(role: .assistant, content: "new", isFinal: true)

        adapter.emitTranscriptForTesting(stale, generation: oldGeneration)
        adapter.emitTranscriptForTesting(current, generation: currentGeneration)

        #expect(await iterator.next() == current)
    }

    @Test("server errors from an old generation do not reach a reconnected stream")
    func staleErrorsAreDroppedAfterTeardown() async {
        let adapter = RealtimeAPIAdapter()
        let oldGeneration = adapter.eventGeneration
        let stream = adapter.errorStream()
        var iterator = stream.makeAsyncIterator()

        await adapter.teardownActiveConversation()
        let currentGeneration = adapter.eventGeneration
        let stale = RealtimeClientError(code: "old", message: "old")
        let current = RealtimeClientError(code: "new", message: "new")

        adapter.emitErrorForTesting(stale, generation: oldGeneration)
        adapter.emitErrorForTesting(current, generation: currentGeneration)

        #expect(await iterator.next() == current)
    }

    @Test("pending tool calls are discarded when the conversation generation changes")
    func pendingToolCallsDoNotReplayAcrossGenerations() async {
        let adapter = RealtimeAPIAdapter()
        let oldGeneration = adapter.eventGeneration
        let stale = RealtimeToolCallEvent(
            callId: "old-call",
            name: "oldTool",
            argumentsJSON: "{}"
        )
        let current = RealtimeToolCallEvent(
            callId: "new-call",
            name: "newTool",
            argumentsJSON: "{}"
        )

        // No subscriber: this enters the adapter's pending FIFO.
        adapter.emitToolCallForTesting(stale, generation: oldGeneration)
        await adapter.teardownActiveConversation()

        let stream = adapter.toolCallStream()
        var iterator = stream.makeAsyncIterator()
        adapter.emitToolCallForTesting(current, generation: adapter.eventGeneration)

        #expect(await iterator.next() == current)
    }

    @Test("a stale generation cannot repopulate pending tool calls")
    func staleToolCallIsRejectedAfterGenerationChange() async {
        let adapter = RealtimeAPIAdapter()
        let oldGeneration = adapter.eventGeneration
        await adapter.teardownActiveConversation()

        let stream = adapter.toolCallStream()
        var iterator = stream.makeAsyncIterator()
        adapter.emitToolCallForTesting(
            RealtimeToolCallEvent(callId: "old", name: "old", argumentsJSON: "{}"),
            generation: oldGeneration
        )
        adapter.emitToolCallForTesting(
            RealtimeToolCallEvent(callId: "current", name: "current", argumentsJSON: "{}"),
            generation: adapter.eventGeneration
        )

        #expect(await iterator.next()?.callId == "current")
    }
}
