import Testing
import Foundation
import RealtimeAPI
@testable import RishiVoice

/// Focused white-box tests for `RealtimeToolCallDispatcher.isArgumentsReady(fc:)`,
/// the tool-call readiness gate extracted from `RealtimeAPIAdapter` (plan 34-13).
/// The adapter now delegates its `isArgumentsReady` seam here; these assertions
/// pin the routing decision at the new home (the adapter-seam tests in
/// `RealtimeAPIAdapterToolCallTests` continue to exercise the forward).
@Suite("RealtimeToolCallDispatcher readiness gate")
struct RealtimeToolCallDispatcherTests {

    /// Construct an `Item.FunctionCall` via JSON round-trip — the SDK's
    /// memberwise init is internal (mirrors the adapter's pcm24k pattern).
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

    @Test("status == completed → ready regardless of arguments")
    func statusCompletedIsReady() throws {
        let dispatcher = RealtimeToolCallDispatcher()
        let fc = try makeFunctionCall(arguments: "", status: "completed")
        #expect(dispatcher.isArgumentsReady(fc: fc) == true)
    }

    @Test("valid JSON object arguments → ready")
    func validObjectIsReady() throws {
        let dispatcher = RealtimeToolCallDispatcher()
        let fc = try makeFunctionCall(arguments: "{\"queryText\":\"hi\"}")
        #expect(dispatcher.isArgumentsReady(fc: fc) == true)
    }

    @Test("empty / non-JSON / array arguments → NOT ready")
    func nonObjectArgumentsAreNotReady() throws {
        let dispatcher = RealtimeToolCallDispatcher()
        for bad in ["", "not json", "[1,2,3]"] {
            let fc = try makeFunctionCall(arguments: bad)
            #expect(dispatcher.isArgumentsReady(fc: fc) == false, "\(bad) should not be ready")
        }
    }

    @Test("adapter seam forwards to the dispatcher identically")
    func adapterSeamMatchesDispatcher() throws {
        let dispatcher = RealtimeToolCallDispatcher()
        let adapter = RealtimeAPIAdapter()
        let fc = try makeFunctionCall(arguments: "{}")
        #expect(adapter.isArgumentsReady(fc: fc) == dispatcher.isArgumentsReady(fc: fc))
    }
}
