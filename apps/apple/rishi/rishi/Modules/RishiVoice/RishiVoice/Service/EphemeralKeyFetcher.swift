import Foundation




/// Sendable response from the worker's `/api/realtime/client_secrets` endpoint.
///
/// `secret` is the OpenAI Realtime ephemeral client secret that gets handed
/// directly to the swift-realtime-openai SDK (`Conversation.connect(ephemeralKey:)`).
/// `sessionId` is the worker-allocated session id used by `/api/realtime/usage`
/// to attribute billing after the WebRTC session terminates.
public struct EphemeralKey: Sendable, Equatable {
    public let secret: String
    public let sessionId: String

    public init(secret: String, sessionId: String) {
        self.secret = secret
        self.sessionId = sessionId
    }
}

/// Injection seam for the ephemeral-key fetch path. Production wires
/// `EphemeralKeyFetcher` (the actor below); RishiVoice tests inject a stub.
/// Extracted in Plan 10-03 so `RealtimeVoiceSession` can be unit-tested with
/// canned key responses without touching `WorkerClient`.
///
/// Phase 25 (Plan 25-08) widened the protocol surface with an optional
/// `BookContextSnapshot`. The default-arg extension below preserves the
/// `fetch(language:)` call shape used by the Plan 10-03 reconnect path in
/// `RealtimeVoiceSession.handleTransientDisconnect()` — that path doesn't
/// have a book context handy on a transient reconnect.
public protocol EphemeralKeyFetching: Sendable {
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey
}

extension EphemeralKeyFetching {
    /// Convenience overload preserved for the Plan 10-03 reconnect path and
    /// any caller that doesn't have a book context handy. Forwards with
    /// `bookContext: nil` — the worker treats that identically to the
    /// pre-Phase-25 GET behavior.
    public func fetch(language: String? = nil) async throws -> EphemeralKey {
        try await fetch(language: language, bookContext: nil)
    }
}

/// Fetches an ephemeral OpenAI Realtime client secret for the iOS WebRTC handoff.
///
/// The worker handles SIWA auth + OpenAI key custody. The iOS client just asks
/// for an ephemeral secret + session id and forwards them to the SDK. This actor
/// wraps the existing `RishiAPI.WorkerClient` and `RealtimeClientSecretsEndpoint`
/// behind a Sendable, narrow surface so Plan 10-03's `RealtimeVoiceSession`
/// actor never needs to know about `WorkerClient` directly.
///
/// As of Phase 25 (Plan 25-08), the request is a POST whose body carries the
/// optional book-context snapshot the worker uses to render the realtime
/// system prompt + register the `bookContext(queryText)` tool server-side.
public actor EphemeralKeyFetcher: EphemeralKeyFetching {

    private let workerClient: WorkerClient

    public init(workerClient: WorkerClient) {
        self.workerClient = workerClient
    }

    /// Fetch a fresh ephemeral key.
    ///
    /// - Parameters:
    ///   - language: optional locale hint the worker uses to tune VAD /
    ///     agent prompts. Pass `nil` to let the worker pick.
    ///   - bookContext: optional snapshot of the iOS reader's state at the
    ///     moment the session starts (current book, page, outline, active
    ///     paragraph). Pass `nil` from contexts that don't have a book —
    ///     for example the reconnect path in
    ///     `RealtimeVoiceSession.handleTransientDisconnect()` — which then
    ///     reproduces the pre-Phase-25 behavior.
    ///
    /// Throws whatever `WorkerClient` throws — typically `RishiError.unauthenticated`
    /// on 401, `RishiError.network(code:message:)` on 4xx, or
    /// `RishiError.networkFailure(URLError)` on transport errors. Callers
    /// branch on the case (Plan 10-03 maps `.unauthenticated` to a "sign in
    /// to use voice" UI surface).
    public func fetch(
        language: String?,
        bookContext: BookContextSnapshot?
    ) async throws -> EphemeralKey {
        let endpoint = RealtimeClientSecretsEndpoint(
            language: language,
            bookContext: bookContext
        )
        do {
            let response = try await workerClient.send(endpoint)
            Log.event("voice.ephemeral.fetched", level: .info, data: [
                "session_id": response.sessionId,
                "has_book_context": String(bookContext != nil),
            ])
            return EphemeralKey(
                secret: response.clientSecret,
                sessionId: response.sessionId
            )
        } catch {
            Log.event("voice.ephemeral.failed", level: .error, data: [
                "error": String(describing: error),
            ])
            throw error
        }
    }
}
