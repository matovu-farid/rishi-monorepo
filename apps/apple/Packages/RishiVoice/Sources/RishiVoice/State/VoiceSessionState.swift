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

    public func reset() {
        self.status = .idle
        self.partialUserTranscript = ""
        self.partialAssistantTranscript = ""
        self.lastError = nil
    }
}
