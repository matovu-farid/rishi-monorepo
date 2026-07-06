import Foundation
import RishiCore
import RishiCore

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

/// Reason a voice session terminated in `.failed`.
public enum VoiceSessionFailureReason: Sendable, Equatable {
    case micDenied
    case keyFetch(KeyFetchFailure)
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
