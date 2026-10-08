import Foundation



/// Result of a successful `POST /api/voice-sessions` call. `nonce` is
/// single-use — retain it only long enough to call `registerCall` once, per
/// the no-card-credit-trial spec's "Voice flow" step 3.
public struct StartedVoiceSession: Sendable, Equatable {
    public let rishiSessionId: String
    public let nonce: String
    public let clientSecret: String
    public let capIntervals: Int
    public let realtimeModel: String

    public init(rishiSessionId: String, nonce: String, clientSecret: String, capIntervals: Int, realtimeModel: String) {
        self.rishiSessionId = rishiSessionId
        self.nonce = nonce
        self.clientSecret = clientSecret
        self.capIntervals = capIntervals
        self.realtimeModel = realtimeModel
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

    /// `POST /api/voice-sessions/end-active` — force-close whichever session
    /// the server considers live. Returns the ended id when one existed.
    func endActiveSessionIfAny() async throws -> String?
}

extension VoiceSessionCoordinating {
    /// Default no-op so Realtime-only test doubles compile until updated.
    public func endSession(rishiSessionId: String) async throws {}

    /// Default no-op — production client overrides.
    public func endActiveSessionIfAny() async throws -> String? { nil }
}

/// Production `VoiceSessionCoordinating`, backed by the existing
/// `WorkerClient`. Actor (not a plain struct) to match `EphemeralKeyFetcher`'s
/// concurrency shape — no mutable state today, but keeps the seam
/// actor-isolated in case a future retry/cache layer needs it.
/// A successful admitted create remains cleanable after its lease is replaced.
/// This capability ends only its own returned ID and never reads live credentials.
struct VoiceSessionCreationReceipt: Sendable {
    let started: StartedVoiceSession
    let lease: CredentialLease
    let endSpecificSession: @Sendable () async throws -> Void
}

public actor VoiceSessionAPIClient: VoiceSessionCoordinating {

    private let workerClient: WorkerClient
    private enum Authentication: Sendable {
        case legacy
        case scoped(ScopedAuthentication)
    }
    private struct ScopedAuthentication: Sendable {
        let authority: SessionCredentialAuthority
        let context: CredentialRequestContext
        let baseURL: URL
        let session: URLSession
        let consent: any WorkerDataUseConsentProvider
    }
    private let authentication: Authentication

    public init(workerClient: WorkerClient) {
        self.workerClient = workerClient
        self.authentication = .legacy
    }

    /// Passive until atomic composition switches. Captured before session creation.
    init(workerClient: WorkerClient, credentialAuthority: SessionCredentialAuthority,
         credentialContext: CredentialRequestContext, baseURL: URL, session: URLSession,
         dataUseConsentProvider: any WorkerDataUseConsentProvider) throws {
        guard case .normal = credentialContext,
              workerClient.usesCredentialAuthority(credentialAuthority) else { throw CredentialAuthenticationFailure.accountChanged }
        self.workerClient = workerClient
        self.authentication = .scoped(.init(authority: credentialAuthority, context: credentialContext,
                                             baseURL: baseURL, session: session, consent: dataUseConsentProvider))
    }

    func startSessionWithReceipt(language: String?, bookContext: BookContextSnapshot?) async throws -> VoiceSessionCreationReceipt {
        guard case .scoped(let scoped) = authentication else { throw CredentialAuthenticationFailure.accountChanged }
        _ = try scoped.authority.snapshot(for: scoped.context)
        let delivery = try await workerClient.sendAdmittedCreation(
            CreateVoiceSessionEndpoint(language: language, bookContext: bookContext), credentialContext: scoped.context
        )
        let response = delivery.response
        let started = StartedVoiceSession(rishiSessionId: response.rishiSessionId, nonce: response.nonce,
                                          clientSecret: response.clientSecret, capIntervals: response.capIntervals,
                                          realtimeModel: response.realtimeModel)
        let cleanup = WorkerClient(baseURL: scoped.baseURL, session: scoped.session,
                                   admittedCleanupBearer: delivery.transmittedBearer,
                                   dataUseConsentProvider: scoped.consent)
        return VoiceSessionCreationReceipt(started: started, lease: delivery.lease) {
            do { _ = try await cleanup.send(EndVoiceSessionEndpoint(rishiSessionId: started.rishiSessionId)) }
            catch { if !Self.isAlreadyTerminalEndError(error) { throw error } }
        }
    }

    func requireCurrentCredentialContext() throws {
        guard case .scoped(let scoped) = authentication else { throw CredentialAuthenticationFailure.accountChanged }
        _ = try scoped.authority.snapshot(for: scoped.context)
    }

    nonisolated func isBound(to authority: SessionCredentialAuthority, context: CredentialRequestContext) -> Bool {
        guard case .scoped(let scoped) = authentication,
              case .normal(let expected) = context, case .normal(let actual) = scoped.context else { return false }
        return scoped.authority === authority && actual == expected
    }

    private func send<E: WorkerEndpoint>(_ endpoint: E) async throws -> E.Response {
        switch authentication {
        case .legacy: return try await workerClient.send(endpoint)
        case .scoped(let scoped):
            _ = try scoped.authority.snapshot(for: scoped.context)
            return try await workerClient.send(endpoint, credentialContext: scoped.context)
        }
    }

    public func startSession(
        language: String?,
        bookContext: BookContextSnapshot?
    ) async throws -> StartedVoiceSession {
        // Scoped creation must deliver its cleanup receipt, never payload only.
        guard case .legacy = authentication else { throw CredentialAuthenticationFailure.accountChanged }
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
                capIntervals: response.capIntervals,
                realtimeModel: response.realtimeModel
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
            _ = try await send(endpoint)
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

    public func endActiveSessionIfAny() async throws -> String? {
        let endpoint = EndActiveVoiceSessionEndpoint()
        do {
            let response = try await send(endpoint)
            if let id = response.rishiSessionId {
                Log.event("voice.session.end_active.succeeded", level: .info, data: [
                    "rishiSessionId": id,
                ])
            } else {
                Log.event("voice.session.end_active.none", level: .info)
            }
            return response.rishiSessionId
        } catch {
            Log.event("voice.session.end_active.failed", level: .warning, data: [
                "error": String(describing: error),
            ])
            throw error
        }
    }

    public func endSession(rishiSessionId: String) async throws {
        let endpoint = EndVoiceSessionEndpoint(rishiSessionId: rishiSessionId)
        do {
            _ = try await send(endpoint)
            Log.event("voice.session.end.succeeded", level: .info, data: [
                "rishiSessionId": rishiSessionId,
            ])
        } catch {
            // Already gone / already terminal is success for client hangup.
            // Registered realtime sessions are NOT auto-orphaned on create —
            // callers must retry real delivery failures.
            if Self.isAlreadyTerminalEndError(error) {
                Log.event("voice.session.end.already_terminal", level: .info, data: [
                    "rishiSessionId": rishiSessionId,
                ])
                return
            }
            Log.event("voice.session.end.failed", level: .warning, data: [
                "rishiSessionId": rishiSessionId,
                "error": String(describing: error),
            ])
            throw error
        }
    }

    /// `NO_ACTIVE_VOICE_SESSION` means the ledger has nothing live to end
    /// (missing row or already reconciled). Treat as successful hangup.
    public static func isAlreadyTerminalEndError(_ error: any Error) -> Bool {
        guard let rishiError = error as? RishiError else { return false }
        if case .network(let code, _) = rishiError {
            return code == WorkerErrorCode.noActiveVoiceSession
        }
        return false
    }
}
