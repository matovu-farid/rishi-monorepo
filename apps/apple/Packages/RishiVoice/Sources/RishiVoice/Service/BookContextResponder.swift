import Foundation
import RishiSearch
import RishiLogging

/// Drains a `RealtimeClientAPI.toolCallStream()` and, for each `bookContext`
/// tool call, looks up the matching passages in the per-book on-device HNSW
/// index via `BookSearch` and writes the result back to the realtime peer via
/// `RealtimeClientAPI.sendToolResult(callId:payload:)`.
///
/// Mirrors `VoiceTranscriptBridge`: same actor + `consume(stream:)` entry-point
/// shape. The Responder owns the loop until the stream finishes or the spawned
/// Task is cancelled by `RealtimeVoiceSession` (Plan 25-10) at session teardown.
///
/// Behavior on each `bookContext` event:
///   1. Decode `argumentsJSON` as `{queryText: String}` — sentinel on failure.
///   2. Gate on `BookSearch.status(bookId:) == .ready` — sentinel otherwise.
///   3. Call `BookSearch.search(queryText:bookId:)`.
///      `.indexNotReady` throw -> sentinel; any other throw -> sentinel.
///   4. Cancellation gate BEFORE encode/send — drops the result silently
///      because a phantom tool result is worse than no tool result.
///   5. Serialize `[BookSearchHit]` as a JSON array
///      `[{"text":"...","page":<int>,"score":<double>}]` (BookSearchHit is
///      Codable with exactly those keys) and `sendToolResult`.
///
/// Tool calls whose `name` is not `bookContext` (e.g. future `endConversation`,
/// `inspectCurrentPage`) are logged + ignored; no tool result is written.
public actor BookContextResponder {

    /// Sentinel returned to the LLM when the per-book index isn't ready.
    /// VERBATIM string — keep in sync with Electron's `buildRealtimeAgent.ts`
    /// and the CONTEXT.md decision for Phase 25.
    public static let coldStartSentinel = "Book context is still being indexed — please ask me to continue in a moment, or proceed without the lookup."

    /// Tool name the Responder recognizes. MUST match `BOOK_CONTEXT_TOOL_SPEC.name`
    /// in `packages/shared/src/voice-chat/build-realtime-agent.ts`.
    public static let toolName = "bookContext"

    private let client: any RealtimeClientAPI
    private let search: any BookSearch
    private let bookId: UUID

    public init(
        client: any RealtimeClientAPI,
        search: any BookSearch,
        bookId: UUID
    ) {
        self.client = client
        self.search = search
        self.bookId = bookId
    }

    /// Drive the responder by consuming a tool-call stream. Returns when the
    /// stream finishes or the Task is cancelled.
    public func consume(stream: AsyncStream<RealtimeToolCallEvent>) async {
        for await event in stream {
            if Task.isCancelled { return }
            await handle(event)
        }
    }

    // MARK: - Internals

    private func handle(_ event: RealtimeToolCallEvent) async {
        guard event.name == Self.toolName else {
            Log.event("voice.tool.unknown", level: .warning, data: [
                "name": event.name,
                "callId": event.callId,
            ])
            return
        }

        // 1. Decode arguments.
        let args: BookContextArgs
        do {
            guard let data = event.argumentsJSON.data(using: .utf8) else {
                throw BookContextArgsError.notUTF8
            }
            args = try JSONDecoder().decode(BookContextArgs.self, from: data)
        } catch {
            Log.event("voice.tool.decode.failed", level: .error, data: [
                "callId": event.callId,
                "argumentsJSON": event.argumentsJSON,
            ])
            await sendSentinel(callId: event.callId, reason: "arg_decode_failed")
            return
        }

        // 2. Status gate (cold-start sentinel).
        let status = await search.status(bookId: bookId)
        guard case .ready = status else {
            Log.event("voice.tool.coldstart", level: .info, data: [
                "callId": event.callId,
                "status": String(describing: status),
            ])
            await sendSentinel(callId: event.callId, reason: "status_not_ready")
            return
        }

        // 3. Search.
        let hits: [BookSearchHit]
        do {
            hits = try await search.search(queryText: args.queryText, bookId: bookId)
        } catch BookContextSearchError.indexNotReady {
            await sendSentinel(callId: event.callId, reason: "search_index_not_ready")
            return
        } catch {
            Log.event("voice.tool.search.failed", level: .error, data: [
                "callId": event.callId,
                "error": String(describing: error),
            ])
            await sendSentinel(callId: event.callId, reason: "search_threw")
            return
        }

        // 4. Cancellation gate BEFORE sending — CONTEXT.md decision: cancelled
        //    queries do NOT write a tool result back to the peer.
        if Task.isCancelled {
            Log.event("voice.tool.cancelled.pre_send", level: .info, data: [
                "callId": event.callId,
            ])
            return
        }

        // 5. Encode + send JSON array of hits. BookSearchHit is Codable with
        //    exactly `text`/`page`/`score` keys, so the wire shape matches
        //    CONTEXT.md verbatim.
        let payload: String
        do {
            let data = try JSONEncoder().encode(hits)
            payload = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            Log.event("voice.tool.encode.failed", level: .error, data: [
                "callId": event.callId,
                "error": String(describing: error),
            ])
            await sendSentinel(callId: event.callId, reason: "encode_failed")
            return
        }

        do {
            try await client.sendToolResult(callId: event.callId, payload: payload)
            Log.event("voice.tool.result.sent", level: .info, data: [
                "callId": event.callId,
                "hits": String(hits.count),
            ])
        } catch {
            Log.event("voice.tool.send.failed", level: .error, data: [
                "callId": event.callId,
                "error": String(describing: error),
            ])
        }
    }

    private func sendSentinel(callId: String, reason: String) async {
        if Task.isCancelled { return }
        do {
            try await client.sendToolResult(callId: callId, payload: Self.coldStartSentinel)
            Log.event("voice.tool.sentinel.sent", level: .info, data: [
                "callId": callId,
                "reason": reason,
            ])
        } catch {
            Log.event("voice.tool.sentinel.send.failed", level: .error, data: [
                "callId": callId,
                "error": String(describing: error),
            ])
        }
    }

    private struct BookContextArgs: Decodable {
        let queryText: String
    }

    private enum BookContextArgsError: Error {
        case notUTF8
    }
}
