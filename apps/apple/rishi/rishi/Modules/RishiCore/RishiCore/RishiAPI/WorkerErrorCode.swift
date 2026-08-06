import Foundation

/// Centralised, named worker error-envelope `code` strings.
///
/// The Rishi worker returns structured 4xx errors as an `ErrorEnvelope`
/// whose `code` is a stable contract string. `WorkerClient.send` surfaces it
/// as `RishiError.network(code:message:)`. These constants document that
/// cross-package contract in ONE place so consumers (e.g. the voice layer's
/// `KeyFetchFailure.classify`) key off a named symbol instead of an
/// undocumented bare literal that silently breaks if the worker's string
/// drifts.
public enum WorkerErrorCode {
    /// HTTP 402 — the TTS allowance reservation was rejected.
    public static let insufficientAllowance = "INSUFFICIENT_ALLOWANCE"

    /// HTTP 402 — the user lacks an active Pro subscription. Worker body:
    /// `{ "error": { "code": "BILLING_INACTIVE", ... } }`. A paywall signal,
    /// NOT a transient/service failure — consumers must surface "subscription
    /// required" rather than invite retry storms against a 402.
    public static let billingInactive = "BILLING_INACTIVE"

    // MARK: - POST /api/voice-sessions (2026-07-17-voice-sessions-route.md)

    /// 409 — this account already has a live voice session.
    public static let voiceSessionAlreadyActive = "VOICE_SESSION_ALREADY_ACTIVE"
    /// 402 — fewer than 2 trial credits remain (or the paid-plan equivalent).
    public static let insufficientTrialCredits = "INSUFFICIENT_TRIAL_CREDITS"
    /// 502 — the ledger session was created but OpenAI's client-secret mint failed. Retryable.
    public static let openAIMintFailed = "OPENAI_MINT_FAILED"

    // MARK: - POST /api/voice-sessions/:id/register-call

    /// 400 — `callId`/`nonce` missing or empty in the request body.
    public static let invalidRegisterCallBody = "INVALID_REGISTER_CALL_BODY"
    /// 400 — `:id` doesn't match this account's currently active session.
    public static let voiceSessionIdMismatch = "VOICE_SESSION_ID_MISMATCH"
    /// 400 — the registration nonce didn't verify.
    public static let registrationNonceInvalid = "REGISTRATION_NONCE_INVALID"
    /// 404 — no active session exists (already terminal, or grace-period expired).
    public static let noActiveVoiceSession = "NO_ACTIVE_VOICE_SESSION"
    /// 409 — this session already completed registration once.
    public static let callAlreadyRegistered = "CALL_ALREADY_REGISTERED"
    /// 409 — this exact nonce was already consumed.
    public static let registrationNonceReplayed = "REGISTRATION_NONCE_REPLAYED"
    /// 500 — unexpected server error (shared by both voice-session routes).
    public static let internalError = "INTERNAL_ERROR"
}

public enum WorkerAllowanceKind: String, Sendable, Equatable, Codable {
    case trial
    case narration
}

/// A worker HTTP 402 that must not be retried and should be routed to the
/// feature-specific upgrade prompt instead of the generic TTS alert.
public struct WorkerAllowanceError: Error, Sendable, Equatable {
    public let kind: WorkerAllowanceKind
    public let message: String

    public init(kind: WorkerAllowanceKind, message: String) {
        self.kind = kind
        self.message = message
    }

    // Compatibility factories keep call sites readable while preserving one
    // canonical, explicitly constructible error shape.
    public static func trial(message: String) -> Self {
        Self(kind: .trial, message: message)
    }

    public static func narration(message: String) -> Self {
        Self(kind: .narration, message: message)
    }

    public var code: String { WorkerErrorCode.insufficientAllowance }
}

extension WorkerAllowanceError: LocalizedError {
    public var errorDescription: String? { message }
}
