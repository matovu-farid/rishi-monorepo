import Foundation

/// Generation fence for activation async work. Invalidated by `cancel`, failure,
/// replacement, or session teardown.
public struct ActivationID: Sendable, Hashable, Equatable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

/// Activation lifecycle states (observability + generation checks).
public enum ActivationState: Sendable, Equatable {
    case idle
    case capturing
    case waitingForSilence
    case injecting
    case armingLiveMic
    case live
    case cancelled
    case failed
}

/// Inject path used for a buffered pre-connect turn.
public enum HandoffInjectPath: String, Sendable, Equatable {
    case path0A
    case path0B
    case path0C
}

/// Transport-level outcome for one inject attempt.
public enum HandoffAcceptance: Sendable, Equatable {
    case accepted(path: HandoffInjectPath)
    case rejected(path: HandoffInjectPath, code: String)
    case ambiguous
    case noSpeech
}

/// Coordinator-level handoff result surfaced to the session.
public enum HandoffOutcome: Sendable, Equatable {
    case liveMicOnly
    case accepted(path: HandoffInjectPath)
    /// PCM inject failed or was ambiguous and no Speech transcript was available.
    case recoveredLiveMic(notice: String)
    case unavailable(reason: String)
    case interrupted
}

extension HandoffOutcome {
    public static let missedUtteranceNotice = "I missed that—please repeat."
}
