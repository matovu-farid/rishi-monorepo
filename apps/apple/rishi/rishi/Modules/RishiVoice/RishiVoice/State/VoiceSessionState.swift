import Foundation
import Observation

/// Presenter-facing observable state. The actor (`RealtimeVoiceSession`)
/// pushes updates via `MainActor.run`; SwiftUI binds via `@Bindable` in
/// Plan 10-05.
@MainActor
@Observable
public final class VoiceSessionState {
    public var status: VoiceSessionStatus = .idle
    public var partialUserTranscript: String = ""
    public var partialAssistantTranscript: String = ""
    public var lastError: String?

    /// Remaining trial credits from the control WebSocket's
    /// `allowance_remaining` / non-terminal `snapshot` messages
    /// (`ControlMessage.remainingTrialCredits`). `nil` before the first
    /// message arrives.
    public var remainingTrialCredits: Int?
    /// Remaining paid-plan Voice Chat seconds from the same messages
    /// (`ControlMessage.remainingVoiceChatSeconds`). `nil` before the first
    /// message arrives.
    public var remainingVoiceChatSeconds: Int?
    /// Remaining session intervals from the same messages.
    public var remainingIntervals: Int?
    /// Set once the control WebSocket sends `session_ending` (final
    /// 30-second interval warning). Cleared by `reset()`. The app layer
    /// (e.g. `VoiceSessionView`) reads this to show a warning banner.
    public var isFinalInterval: Bool = false

    /// Main-actor lifecycle gate used to serialize terminal teardown against
    /// a pending `.live` publication from an async transport callback.
    private var lifecycleToken: UUID?
    private var lifecycleIsEnding = false

    /// Chrome waveform / status hint. Updated by ``apply(status:)`` and
    /// ``VoiceTranscriptBridge`` transcript events.
    public var activityPhase: VoiceActivityPhase = .connecting

    public init() {}

    /// Begins a new session lifecycle. This is intentionally separate from
    /// `reset()` so a reset cannot accidentally reopen a session that is
    /// already being torn down.
    public func beginLifecycle(_ token: UUID) {
        guard lifecycleToken != token else { return }
        lifecycleToken = token
        lifecycleIsEnding = false
    }

    /// Marks teardown before any async transport cleanup begins.
    public func beginEndingLifecycle(_ token: UUID) {
        guard lifecycleToken == token else { return }
        lifecycleIsEnding = true
    }

    /// Publishes `.live` only if teardown has not already won the lifecycle
    /// race. The check and mutation share MainActor isolation.
    @discardableResult
    public func applyLiveIfActive(_ token: UUID) -> Bool {
        guard lifecycleToken == token, !lifecycleIsEnding else { return false }
        apply(status: .live)
        return true
    }

    /// Publishes a failure only while the originating session still owns the
    /// shared state object.
    @discardableResult
    public func applyFailureIfActive(
        _ token: UUID,
        reason: VoiceSessionFailureReason,
        message: String?
    ) -> Bool {
        guard lifecycleToken == token else { return false }
        apply(status: .failed(reason: reason))
        if let message { recordError(message) }
        return true
    }

    public func apply(status: VoiceSessionStatus) {
        self.status = status
        switch status {
        case .reconnecting:
            activityPhase = .reconnecting
        case .live:
            activityPhase = .listening
        case .idle, .requestingMic, .fetchingKey, .creatingSession, .connecting, .registeringCall:
            activityPhase = .connecting
        case .failed:
            activityPhase = .connecting
        case .ending, .ended:
            break
        }
    }

    public func apply(activityPhase: VoiceActivityPhase) {
        self.activityPhase = activityPhase
    }

    /// Append a (likely partial) transcript fragment. Finals are persisted via
    /// `VoiceTranscriptBridge` and left visible; the bridge calls
    /// `clearTranscript(role:)` only when that role starts its next utterance.
    public func appendTranscript(role: TranscriptRole, content: String) {
        switch role {
        case .user:      partialUserTranscript += content
        case .assistant: partialAssistantTranscript += content
        }
    }

    public func clearTranscript(role: TranscriptRole) {
        switch role {
        case .user:      partialUserTranscript = ""
        case .assistant: partialAssistantTranscript = ""
        }
    }

    public func recordError(_ message: String) {
        self.lastError = message
    }

    /// Applies a control-WebSocket allowance update — either an
    /// `allowance_remaining` message (fields always present) or the
    /// non-terminal branch of a `snapshot` message (fields optional per
    /// `ControlMessage.snapshot`'s decoding; pass through as given).
    public func applyAllowance(
        remainingTrialCredits: Int?,
        remainingVoiceChatSeconds: Int?,
        remainingIntervals: Int?
    ) {
        if let remainingTrialCredits { self.remainingTrialCredits = remainingTrialCredits }
        if let remainingVoiceChatSeconds { self.remainingVoiceChatSeconds = remainingVoiceChatSeconds }
        if let remainingIntervals { self.remainingIntervals = remainingIntervals }
    }

    /// Applies a control-WebSocket `session_ending` warning.
    public func applySessionEndingWarning() {
        isFinalInterval = true
    }

    public func reset() {
        self.status = .idle
        self.partialUserTranscript = ""
        self.partialAssistantTranscript = ""
        self.lastError = nil
        self.remainingTrialCredits = nil
        self.remainingVoiceChatSeconds = nil
        self.remainingIntervals = nil
        self.isFinalInterval = false
        self.activityPhase = .connecting
    }
}
