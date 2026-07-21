import Foundation
import RishiCore
import RishiLogging

/// Result of a successful `POST /api/voice-sessions` call. `nonce` is
/// single-use — retain it only long enough to call `registerCall` once, per
/// the no-card-credit-trial spec's "Voice flow" step 3.
public struct StartedVoiceSession: Sendable, Equatable {
    public let rishiSessionId: String
    public let nonce: String
    public let clientSecret: String
    public let capIntervals: Int

    public init(rishiSessionId: String, nonce: String, clientSecret: String, capIntervals: Int) {
        self.rishiSessionId = rishiSessionId
        self.nonce = nonce
        self.clientSecret = clientSecret
        self.capIntervals = capIntervals
    }
}

/// Injection seam for the two-step voice-session-creation flow. Production
/// wires `VoiceSessionAPIClient`; `RishiVoice` tests inject a stub. Mirrors
/// the existing `EphemeralKeyFetching` seam pattern exactly.
public protocol VoiceSessionCoordinating: Sendable {
    /// `POST /api/voice-sessions` — the no-card-credit-trial spec's "Voice
    /// flow" step 1–2. Throws `RishiError` (typically `.network(code:message:)`
    /// with one of the codes `VoiceSessionStartFailure.classify` maps, or
    /// `.unauthenticated`, or `.networkFailure`).
    func startSession(language: String?, bookContext: BookContextSnapshot?) async throws -> StartedVoiceSession

    /// `POST /api/voice-sessions/:id/register-call` — "Voice flow" step 3–5.
    /// Throws `RishiError` the same way; every thrown error means the caller
    /// must close the just-opened OpenAI WebRTC connection (see
    /// `VoiceSessionRegistrationFailure`).
    func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws

    /// `POST /api/voice-sessions/:id/end` — client hangup so the ledger does
    /// not stay `active` after intentional End / local teardown.
    func endSession(rishiSessionId: String) async throws
}

extension VoiceSessionCoordinating {
    /// Default no-op so Realtime-only test doubles compile until updated.
    public func endSession(rishiSessionId: String) async throws {}
}

/// Production `VoiceSessionCoordinating`, backed by the existing
/// `WorkerClient`. Actor (not a plain struct) to match `EphemeralKeyFetcher`'s
/// concurrency shape — no mutable state today, but keeps the seam
/// actor-isolated in case a future retry/cache layer needs it.
public actor VoiceSessionAPIClient: VoiceSessionCoordinating {

    private let workerClient: WorkerClient

    public init(workerClient: WorkerClient) {
        self.workerClient = workerClient
    }

    public func startSession(
        language: String?,
        bookContext: BookContextSnapshot?
    ) async throws -> StartedVoiceSession {
        let endpoint = CreateVoiceSessionEndpoint(language: language, bookContext: bookContext)
        do {
            let response = try await workerClient.send(endpoint)
            Log.event("voice.session.create.succeeded", level: .info, data: [
                "rishiSessionId": response.rishiSessionId,
                "capIntervals": String(response.capIntervals),
            ])
            return StartedVoiceSession(
                rishiSessionId: response.rishiSessionId,
                nonce: response.nonce,
                clientSecret: response.clientSecret,
                capIntervals: response.capIntervals
            )
        } catch {
            Log.event("voice.session.create.failed", level: .error, data: [
                "error": String(describing: error),
            ])
            throw error
        }
    }

    public func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws {
        let endpoint = RegisterVoiceCallEndpoint(rishiSessionId: rishiSessionId, callId: callId, nonce: nonce)
        do {
            _ = try await workerClient.send(endpoint)
            Log.event("voice.session.register_call.succeeded", level: .info, data: [
                "rishiSessionId": rishiSessionId,
            ])
        } catch {
            Log.event("voice.session.register_call.failed", level: .error, data: [
                "rishiSessionId": rishiSessionId,
                "error": String(describing: error),
            ])
            throw error
        }
    }

    public func endSession(rishiSessionId: String) async throws {
        let endpoint = EndVoiceSessionEndpoint(rishiSessionId: rishiSessionId)
        do {
            _ = try await workerClient.send(endpoint)
            Log.event("voice.session.end.succeeded", level: .info, data: [
                "rishiSessionId": rishiSessionId,
            ])
        } catch {
            // Best-effort: local UI teardown must proceed even if the network
            // fails; orphan cleanup on next create covers the gap.
            Log.event("voice.session.end.failed", level: .warning, data: [
                "rishiSessionId": rishiSessionId,
                "error": String(describing: error),
            ])
            throw error
        }
    }
}
