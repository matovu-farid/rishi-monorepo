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

    public init() {}

    public func apply(status: VoiceSessionStatus) {
        self.status = status
    }

    /// Append a (likely partial) transcript fragment. Final fragments are
    /// persisted via `VoiceTranscriptBridge` (Plan 10-04) and SHOULD be
    /// followed by `clearTranscript(role:)` to reset the live buffer.
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
    }
}
