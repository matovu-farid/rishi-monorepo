import Foundation



/// Why an ephemeral-key fetch failed. Distinguishes the four states that
/// previously collapsed into one opaque `.keyFetch` reason so the UI (and
/// logs) can tell "signed out" from "not subscribed" from "server route
/// missing / down" from "no connectivity".
public enum KeyFetchFailure: Sendable, Equatable {
    /// 401 — session expired / signed out.
    case unauthorized
    /// 402 — Pro subscription required.
    case subscriptionRequired
    /// 404 / 5xx — server route missing or down.
    case serviceUnavailable
    /// Transport failure (no connectivity).
    case network
    /// Anything else, carries a description.
    case unknown(String)

    /// Pure mapper from a thrown error (typically `RishiError` from the
    /// network layer) to a classified key-fetch failure. Unit-testable.
    public static func classify(_ error: any Error) -> KeyFetchFailure {
        guard let rishiError = error as? RishiError else {
            return .unknown(String(describing: error))
        }
        switch rishiError {
        case .unauthenticated:
            return .unauthorized
        case .network(let code, _):
            // Key off the centralised cross-package contract constant rather
            // than a bare literal. The worker returns HTTP 402 with this code
            // for a paywall (subscription required); everything else 4xx/5xx
            // is a service failure.
            return code == WorkerErrorCode.billingInactive
                ? .subscriptionRequired
                : .serviceUnavailable
        case .networkFailure:
            return .network
        default:
            return .unknown(String(describing: error))
        }
    }
}

/// Why `POST /api/voice-sessions` (the no-card-credit-trial "Voice flow"
/// step 1–2) failed. Mirrors `KeyFetchFailure`'s classify-from-`RishiError`
/// pattern, keyed off the wire codes `2026-07-17-voice-sessions-route.md`
/// documents.
public enum VoiceSessionStartFailure: Sendable, Equatable {
    /// 409 — this account already has a live voice session.
    case alreadyActive
    /// 402 — fewer than 2 trial credits remain (or paid-plan equivalent exhausted).
    case insufficientCredits
    /// 502 — the ledger session was created but the OpenAI mint failed. Retryable.
    case mintFailed
    /// 401 — session expired / signed out.
    case unauthorized
    /// 500 or any other unmapped 4xx/5xx — server route failing.
    case serviceUnavailable
    /// Transport failure (no connectivity).
    case network
    /// Anything else, carries a description.
    case unknown(String)

    public static func classify(_ error: any Error) -> VoiceSessionStartFailure {
        guard let rishiError = error as? RishiError else { return .unknown(String(describing: error)) }
        switch rishiError {
        case .unauthenticated:
            return .unauthorized
        case .network(let code, _):
            switch code {
            case WorkerErrorCode.voiceSessionAlreadyActive: return .alreadyActive
            case WorkerErrorCode.insufficientTrialCredits:  return .insufficientCredits
            case WorkerErrorCode.openAIMintFailed:          return .mintFailed
            default:                                         return .serviceUnavailable
            }
        case .networkFailure:
            return .network
        default:
            return .unknown(String(describing: error))
        }
    }
}

/// Why `POST /api/voice-sessions/:id/register-call` failed (the no-card-
/// credit-trial "Voice flow" step 3–5), OR why registration was never even
/// attempted (`.missingCallId` — the vendored connector never captured a
/// call ID, e.g. a missing `Location` header). Every case here means the
/// caller MUST have already closed the just-opened OpenAI WebRTC connection
/// — see `RealtimeVoiceSession.startTrialVoiceSession`.
public enum VoiceSessionRegistrationFailure: Sendable, Equatable {
    /// The vendored connector never captured a provider call ID after a
    /// successful `connect()` — no HTTP call was even made.
    case missingCallId
    /// 400 — `callId`/`nonce` missing or empty (should not happen from this client; defensive).
    case invalidBody
    /// 400 — `:id` doesn't match this account's active session.
    case sessionIdMismatch
    /// 400 — the registration nonce didn't verify.
    case nonceInvalid
    /// 404 — no active session exists (already terminal, or grace period expired).
    case noActiveSession
    /// 409 — this session already completed registration once.
    case callAlreadyRegistered
    /// 409 — this exact nonce was already consumed.
    case nonceReplayed
    /// 401 — session expired / signed out.
    case unauthorized
    /// 500 or any other unmapped 4xx/5xx.
    case serviceUnavailable
    /// Transport failure (no connectivity).
    case network
    /// Anything else, carries a description.
    case unknown(String)

    public static func classify(_ error: any Error) -> VoiceSessionRegistrationFailure {
        guard let rishiError = error as? RishiError else { return .unknown(String(describing: error)) }
        switch rishiError {
        case .unauthenticated:
            return .unauthorized
        case .network(let code, _):
            switch code {
            case WorkerErrorCode.invalidRegisterCallBody:     return .invalidBody
            case WorkerErrorCode.voiceSessionIdMismatch:      return .sessionIdMismatch
            case WorkerErrorCode.registrationNonceInvalid:    return .nonceInvalid
            case WorkerErrorCode.noActiveVoiceSession:        return .noActiveSession
            case WorkerErrorCode.callAlreadyRegistered:       return .callAlreadyRegistered
            case WorkerErrorCode.registrationNonceReplayed:   return .nonceReplayed
            default:                                           return .serviceUnavailable
            }
        case .networkFailure:
            return .network
        default:
            return .unknown(String(describing: error))
        }
    }
}

/// Reason a voice session terminated in `.failed`.
public enum VoiceSessionFailureReason: Sendable, Equatable {
    case dataUseConsentRequired
    case micDenied
    case keyFetch(KeyFetchFailure)
    /// `POST /api/voice-sessions` failed. Trial-voice-session flow only.
    case sessionStart(VoiceSessionStartFailure)
    /// `POST /api/voice-sessions/:id/register-call` failed, or the call ID
    /// was never captured. Trial-voice-session flow only.
    case callRegistration(VoiceSessionRegistrationFailure)
    case connect
    case networkLost
    case audioSession
    /// The control WebSocket's mandatory `onTerminal` callback fired
    /// (`session_ended` or a terminal `snapshot`). `reason` is
    /// `ControlTerminalReason` — the exact type exported by the landed
    /// "voice-control-websocket-client" plan (`Service/ControlMessage.swift`
    /// in this package): `.voiceSessionTimeCap`, `.trialCreditsExhausted`,
    /// `.registrationTimeout`, `.planVoiceAllowanceExhausted`,
    /// `.providerHangupFailed`, or `.unknown(String)` for forward
    /// compatibility with a server-added reason. Trial-voice-session flow
    /// only.
    case sessionTerminated(reason: ControlTerminalReason)
    /// Local End / dismiss already tore down WebRTC and audio, but background
    /// `POST …/end` delivery failed after retries. Informational only —
    /// auto-retry already ran; do not offer "Try again" that starts a new session.
    case sessionEndFailed
    case unknown(String)
}

/// Lifecycle FSM for a single voice session.
///
/// Legacy flow (`sessionCoordinator == nil`):
/// ```
/// idle → requestingMic → fetchingKey → connecting → live
///                                         ↓
///                                       live → reconnecting(N) → live (success)
///                                                              → failed(.networkLost) (3 attempts exhausted)
///                                       live → ending → ended
///   <any> → failed(reason)
/// ```
///
/// Trial-voice-session flow (`sessionCoordinator != nil`):
/// ```
/// idle → requestingMic → creatingSession → connecting → registeringCall → live
///                                                                            ↓
///                                     live → reconnecting(N) → live   (WebRTC-level; unchanged mechanism)
///                                     live → ending → ended            (user-initiated end())
///                                     live → failed(.sessionTerminated) (control-WS session_ended)
///   <any> → failed(reason)
/// ```
public enum VoiceSessionStatus: Sendable, Equatable {
    case idle
    case requestingMic
    /// Legacy flow only: minting a plain ephemeral key (no Rishi session).
    case fetchingKey
    /// Trial-voice-session flow only: `POST /api/voice-sessions`.
    case creatingSession
    /// Both flows: OpenAI WebRTC `connect()`.
    case connecting
    /// Trial-voice-session flow only: `POST /api/voice-sessions/:id/register-call`.
    case registeringCall
    case live
    case reconnecting(attempt: Int)
    case ending
    case ended
    case failed(reason: VoiceSessionFailureReason)
}
