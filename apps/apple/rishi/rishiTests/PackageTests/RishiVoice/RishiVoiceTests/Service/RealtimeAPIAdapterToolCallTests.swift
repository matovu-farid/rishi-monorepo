@testable import rishi
import Testing
import Foundation



/// White-box tests for `RealtimeAPIAdapter.isArgumentsReady(fc:)` — the
/// readiness gate that closes RESEARCH OQ-Q11-7. The pinned swift-realtime-openai
/// SDK may not flip `Item.FunctionCall.status` to `.completed` when
/// `responseFunctionCallArgumentsDone` fires; the gate accepts either signal:
/// explicit `.completed` status OR `arguments` parses as a valid JSON object.
///
/// Black-box adapter pump tests are deferred to Plan 25-12 integration tests
/// (which use `FakeRealtimeClient` — see `FakeRealtimeClientToolCallTests`).
/// Driving the real Conversation requires a live WebRTC peer.
@Suite("RealtimeAPIAdapter tool-call readiness gate")
struct RealtimeAPIAdapterToolCallTests {

    /// Helper to construct an `Item.FunctionCall` via JSON round-trip — the
    /// SDK's memberwise init is internal, mirroring the pcm24k pattern in
    /// `RealtimeAPIAdapter.connect(...)`.
    private func makeFunctionCall(
        id: String = "item-1",
        callId: String = "call-1",
        name: String = "bookContext",
        arguments: String,
        status: String = "in_progress"
    ) throws -> Item.FunctionCall {
        let payload: [String: Any] = [
            "id": id,
            "status": status,
            "callId": callId,
            "name": name,
            "arguments": arguments,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(Item.FunctionCall.self, from: data)
    }

    @Test("status == completed → ready (regardless of arguments)")
    func statusCompletedIsReady() throws {
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "", status: "completed")
        #expect(adapter.isArgumentsReady(fc: fc) == true)
    }

    @Test("arguments == \"{}\" → ready (valid JSON object)")
    func emptyJsonObjectIsReady() throws {
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "{}")
        #expect(adapter.isArgumentsReady(fc: fc) == true)
    }

    @Test("arguments == \"not json\" → NOT ready")
    func nonJsonIsNotReady() throws {
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "not json")
        #expect(adapter.isArgumentsReady(fc: fc) == false)
    }

    @Test("arguments == \"\" → NOT ready")
    func emptyArgumentsAreNotReady() throws {
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "")
        #expect(adapter.isArgumentsReady(fc: fc) == false)
    }

    @Test("arguments == valid object with queryText → ready")
    func validObjectWithQueryTextIsReady() throws {
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "{\"queryText\":\"hello world\"}")
        #expect(adapter.isArgumentsReady(fc: fc) == true)
    }

    @Test("arguments == JSON array (not object) → NOT ready")
    func jsonArrayIsNotReady() throws {
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "[1,2,3]")
        #expect(adapter.isArgumentsReady(fc: fc) == false)
    }
}
