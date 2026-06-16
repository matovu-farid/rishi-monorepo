import Testing
import Foundation
@testable import RishiVoice

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
}
