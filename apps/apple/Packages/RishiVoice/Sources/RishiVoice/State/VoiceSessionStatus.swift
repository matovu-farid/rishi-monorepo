import Foundation

/// Reason a voice session terminated in `.failed`.
public enum VoiceSessionFailureReason: Sendable, Equatable {
    case micDenied
    case keyFetch
    case connect
    case networkLost
    case audioSession
    case unknown(String)
}

/// Lifecycle FSM for a single voice session. Strict ordering:
///
/// `.idle → .requestingMic → .fetchingKey → .connecting → .live`
/// `.live → .reconnecting(N) → .live` (transient disconnect path)
/// `.live → .ending → .ended` (user-initiated end)
/// `<any> → .failed(reason)` (terminal failure)
public enum VoiceSessionStatus: Sendable, Equatable {
    case idle
    case requestingMic
    case fetchingKey
    case connecting
    case live
    case reconnecting(attempt: Int)
    case ending
    case ended
    case failed(reason: VoiceSessionFailureReason)
}
