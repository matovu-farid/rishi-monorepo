import Foundation

/// Stable, sanitized errors shown by the Read Aloud UI.
///
/// This type deliberately does not carry server/provider text. Transport and
/// playback errors are useful in logs, but their descriptions are not a safe
/// or stable user-facing contract.
public enum TTSUserFacingError: String, Sendable, Equatable, Hashable, Identifiable {
    case trialExhausted
    case narrationExhausted
    case dataUseConsent
    case authentication
    case subscriptionRequired
    case invalidRequest
    case network
    case serviceUnavailable
    case audioPlayback

    public var id: String { rawValue }

    public var title: String { "Read Aloud" }

    public var message: String {
        switch self {
        case .trialExhausted:
            return "You're out of trial credits. Upgrade to keep listening."
        case .narrationExhausted:
            return "You've used your included narration credits. Upgrade to keep listening."
        case .dataUseConsent:
            return "Allow Rishi to process this text for narration, then try again."
        case .authentication:
            return "Please sign in again before using Read Aloud."
        case .subscriptionRequired:
            return "A subscription is required to use Read Aloud."
        case .invalidRequest:
            return "This passage could not be read aloud. Try another passage."
        case .network:
            return "Check your internet connection and try again."
        case .serviceUnavailable:
            return "Read Aloud is temporarily unavailable. Please try again."
        case .audioPlayback:
            return "Audio playback failed. Please try again."
        }
    }

    public var canRetry: Bool {
        switch self {
        case .network, .serviceUnavailable, .audioPlayback:
            return true
        default:
            return false
        }
    }

    public static func classify(_ error: Error) -> Self? {
        if let allowance = error as? WorkerAllowanceError {
            return allowance.kind == .trial ? .trialExhausted : .narrationExhausted
        }
        if error is WorkerDataUseConsentRequiredError {
            return .dataUseConsent
        }
        if let error = error as? RishiError {
            switch error {
            case .cancelled:
                return nil
            case .unauthenticated:
                return .authentication
            case .networkFailure:
                return .network
            case .subscription:
                return .subscriptionRequired
            case .network(let code, _):
                if code == WorkerErrorCode.billingInactive {
                    return .subscriptionRequired
                }
                if code.hasPrefix("http_429") || code.hasPrefix("http_5") {
                    return .serviceUnavailable
                }
                if code.hasPrefix("http_4") {
                    return .invalidRequest
                }
                return .serviceUnavailable
            case .decoding, .persistence, .notFound:
                return .serviceUnavailable
            }
        }
        if error is CancellationError {
            return nil
        }
        return .serviceUnavailable
    }
}
