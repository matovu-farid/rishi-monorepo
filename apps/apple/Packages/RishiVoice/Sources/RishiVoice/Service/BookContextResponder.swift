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

    /// Returned to the LLM when the on-device lookup exceeds `timeoutSeconds`.
    /// Instructs the model to tell the user the lookup failed rather than
    /// waiting on a tool result that may never arrive.
    public static let lookupTimedOutMessage = "The book lookup took too long and was cancelled. Tell the user you weren't able to retrieve anything from the book right now, then answer from what you already know if you can."

    /// Returned to the LLM when the lookup fails for any reason other than a
    /// not-yet-ready index (search threw, bad arguments, encode failure).
    public static let lookupFailedMessage = "The book lookup failed. Tell the user you weren't able to retrieve anything from the book right now, then answer from what you already know if you can."

    private let client: any RealtimeClientAPI
    private let search: any BookSearch
    private let bookId: UUID
    private let timeoutSeconds: Double

    public init(
        client: any RealtimeClientAPI,
        search: any BookSearch,
        bookId: UUID,
        timeoutSeconds: Double = 8
    ) {
        self.client = client
        self.search = search
        self.bookId = bookId
        self.timeoutSeconds = timeoutSeconds
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

        Log.event("voice.tool.start", level: .info, data: [
            "callId": event.callId,
            "name": event.name,
            "timeoutSeconds": String(timeoutSeconds),
        ])

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
            await sendPayload(
                callId: event.callId,
                payload: Self.lookupFailedMessage,
                logEvent: "voice.tool.error.sent",
                reason: "arg_decode_failed"
            )
            return
        }

        // 2. Status gate. Ready proceeds to search; in-progress or missing
        //    index keeps the cold-start sentinel; failed indexing surfaces a
        //    real error so we don't tell the user "still indexing" when the
        //    database actually broke.
        let status = await search.status(bookId: bookId)
        switch status {
        case .ready:
            break
        case .failed(let reason):
            Log.event("voice.tool.status.failed", level: .error, data: [
                "callId": event.callId,
                "reason": reason,
            ])
            await sendPayload(
                callId: event.callId,
                payload: Self.lookupFailedMessage,
                logEvent: "voice.tool.error.sent",
                reason: "status_failed"
            )
            return
        case .indexing, .notIndexed, .staleIndexing:
            Log.event("voice.tool.coldstart", level: .info, data: [
                "callId": event.callId,
                "status": String(describing: status),
            ])
            await sendSentinel(callId: event.callId, reason: "status_not_ready")
            return
        }

        // 3. Search, bounded by a timeout so a stuck lookup surfaces an error
        //    instead of hanging the turn forever.
        let hits: [BookSearchHit]
        do {
            let query = args.queryText
            let book = bookId
            let lookup = search
            hits = try await withToolTimeout(seconds: timeoutSeconds) {
                try await lookup.search(queryText: query, bookId: book)
            }
        } catch is ToolTimeoutError {
            Log.event("voice.tool.timeout", level: .error, data: [
                "callId": event.callId,
                "timeoutSeconds": String(timeoutSeconds),
            ])
            await sendPayload(
                callId: event.callId,
                payload: Self.lookupTimedOutMessage,
                logEvent: "voice.tool.timeout.sent",
                reason: "timeout"
            )
            return
        } catch BookContextSearchError.indexNotReady {
            await sendSentinel(callId: event.callId, reason: "search_index_not_ready")
            return
        } catch {
            Log.event("voice.tool.search.failed", level: .error, data: [
                "callId": event.callId,
                "error": String(describing: error),
            ])
            await sendPayload(
                callId: event.callId,
                payload: Self.lookupFailedMessage,
                logEvent: "voice.tool.error.sent",
                reason: "search_threw"
            )
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
            await sendPayload(
                callId: event.callId,
                payload: Self.lookupFailedMessage,
                logEvent: "voice.tool.error.sent",
                reason: "encode_failed"
            )
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
        await sendPayload(
            callId: callId,
            payload: Self.coldStartSentinel,
            logEvent: "voice.tool.sentinel.sent",
            reason: reason
        )
    }

    private func sendPayload(
        callId: String,
        payload: String,
        logEvent: String,
        reason: String
    ) async {
        if Task.isCancelled { return }
        do {
            try await client.sendToolResult(callId: callId, payload: payload)
            Log.event(logEvent, level: .info, data: [
                "callId": callId,
                "reason": reason,
            ])
        } catch {
            Log.event("voice.tool.send.failed", level: .error, data: [
                "callId": callId,
                "reason": reason,
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

/// Thrown when a bounded tool operation exceeds its deadline.
private struct ToolTimeoutError: Error {}

/// Race `operation` against a deadline. Returns the operation's value if it
/// finishes first; otherwise throws `ToolTimeoutError`. The losing child task
/// is cancelled when the group returns.
private func withToolTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ToolTimeoutError()
        }
        guard let result = try await group.next() else {
            throw ToolTimeoutError()
        }
        group.cancelAll()
        return result
    }
}
