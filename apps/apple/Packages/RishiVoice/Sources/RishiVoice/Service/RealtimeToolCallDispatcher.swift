import Foundation
import RealtimeAPI
import RishiLogging

/// Tool-call readiness gate + result-dispatch encoding extracted from
/// `RealtimeAPIAdapter`. Single responsibility: decide when an inbound
/// `Item.FunctionCall` is ready to surface, and encode a tool-call result back
/// into the SDK's `Conversation`. The adapter owns the `Conversation`; the
/// dispatcher is a stateless helper it calls.
struct RealtimeToolCallDispatcher: Sendable {

    /// Returns true when an inbound `Item.FunctionCall` is ready to dispatch.
    /// The pinned SDK does NOT explicitly flip `status` to `.completed` when
    /// `responseFunctionCallArgumentsDone` fires (verified by reading the SDK
    /// at `~/Library/.../swift-realtime-openai/Sources/UI/Conversation.swift`).
    /// We accept either signal: explicit `.completed` status OR `arguments`
    /// parses as a valid JSON object.
    func isArgumentsReady(fc: Item.FunctionCall) -> Bool {
        // Robust to SDK enum case-rename (no direct comparison to .completed
        // because the SDK module is imported lazily by callers).
        if String(describing: fc.status) == "completed" { return true }
        guard let data = fc.arguments.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Encode + send a tool-call result back to the realtime peer through the
    /// supplied `Conversation`. Throws a `RealtimeClientError` on send failure.
    ///
    /// The `Conversation` is `@MainActor`-isolated, so the send hops to main.
    func sendResult(
        callId: String,
        payload: String,
        on conversation: Conversation
    ) async throws {
        let outputId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            try await MainActor.run {
                try conversation.send(result: Item.FunctionCallOutput(
                    id: outputId,
                    callId: callId,
                    output: payload
                ))
                // The Realtime API does NOT auto-continue from a function
                // output — server-VAD only auto-creates a response on user
                // speech-stop. Without an explicit response.create here the
                // model never speaks the answer and the turn hangs forever.
                try conversation.send(event: .createResponse())
            }
        } catch {
            throw RealtimeClientError(
                code: "send_failed",
                message: String(describing: error)
            )
        }
        Log.event("voice.tool.result.sent", level: .info, data: [
            "callId": callId,
            "payloadBytes": String(payload.utf8.count),
        ])
    }
}
