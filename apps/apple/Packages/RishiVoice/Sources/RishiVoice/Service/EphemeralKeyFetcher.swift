import Foundation
import RishiCore
import RishiAPI
import RishiLogging

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

/// Fetches an ephemeral OpenAI Realtime client secret for the iOS WebRTC handoff.
///
/// The worker handles SIWA auth + OpenAI key custody. The iOS client just asks
/// for an ephemeral secret + session id and forwards them to the SDK. This actor
/// wraps the existing `RishiAPI.WorkerClient` and `RealtimeClientSecretsEndpoint`
/// (shipped in Phase 2) behind a Sendable, narrow surface so Plan 10-03's
/// `RealtimeVoiceSession` actor never needs to know about `WorkerClient`
/// directly.
public actor EphemeralKeyFetcher {

    private let workerClient: WorkerClient

    public init(workerClient: WorkerClient) {
        self.workerClient = workerClient
    }

    /// Fetch a fresh ephemeral key. `language` is the optional `?language=`
    /// hint the worker uses to tune VAD / locale-aware agent prompts. Pass
    /// `nil` to let the worker pick (mirrors Spike B's behavior when the env
    /// supplies no language).
    ///
    /// Throws whatever `WorkerClient` throws — typically `RishiError.unauthenticated`
    /// on 401, `RishiError.network(code:message:)` on 4xx, or
    /// `RishiError.networkFailure(URLError)` on transport errors. Callers
    /// branch on the case (Plan 10-03 maps `.unauthenticated` to a "sign in
    /// to use voice" UI surface).
    public func fetch(language: String? = nil) async throws -> EphemeralKey {
        let endpoint = RealtimeClientSecretsEndpoint(language: language)
        do {
            let response = try await workerClient.send(endpoint)
            Log.event("voice.ephemeral.fetched", level: .info, data: [
                "session_id": response.sessionId,
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
