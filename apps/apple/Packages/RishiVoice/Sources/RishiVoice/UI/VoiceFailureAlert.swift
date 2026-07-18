import Foundation

/// Pure presentation value for a voice-session failure, surfaced as a native
/// SwiftUI `.alert` on the library/reader underneath the (now-unmounted) voice
/// cover rather than a full-screen custom error view.
///
/// Maps a ``VoiceSessionFailureReason`` to the user-facing title/message copy
/// and the single primary affordance ("Open Settings" for `.micDenied`,
/// "Try again" for every other reason). A caller-supplied `message` override
/// (e.g. `VoiceSessionState.lastError`) wins over the default body copy.
///
/// Kept pure (no UIKit / SwiftUI): the app layer owns the Settings deep-link
/// and the alert presentation; this type only carries the strings + the
/// action discriminator so the mapping stays unit-testable.
public struct VoiceFailureAlert: Equatable, Sendable {

    /// The single primary affordance the alert offers.
    public enum PrimaryAction: Equatable, Sendable {
        /// Deep-link to the Settings app — `.micDenied` only, because there is
        /// no in-app way to re-request the microphone after a denial.
        case openSettings
        /// Restart the failed session (every non-`.micDenied`,
        /// non-exhaustion reason).
        case retry
        /// Open the same paywall path as the Voice Chat entry upgrade prompt
        /// (`.sessionStart(.insufficientCredits)` and exhaustion-shaped
        /// terminal reasons).
        case upgrade
        /// Acknowledge-only — reserved for rare terminal cases with no
        /// retry and no upgrade path.
        case dismiss
    }

    public let title: String
    public let message: String
    public let primaryAction: PrimaryAction

    public init(reason: VoiceSessionFailureReason, message: String?) {
        self.title = Self.title(for: reason)
        self.message = message ?? Self.bodyCopy(for: reason)
        self.primaryAction = Self.primaryAction(for: reason)
    }

    private static func primaryAction(for reason: VoiceSessionFailureReason) -> PrimaryAction {
        switch reason {
        case .micDenied:
            return .openSettings
        case .sessionStart(.insufficientCredits):
            return .upgrade
        case .sessionTerminated(let terminationReason) where Self.isExhaustionReason(terminationReason):
            return .upgrade
        default:
            return .retry
        }
    }

    private static func isExhaustionReason(_ reason: ControlTerminalReason) -> Bool {
        switch reason {
        case .trialCreditsExhausted, .planVoiceAllowanceExhausted:
            return true
        case .voiceSessionTimeCap, .registrationTimeout, .providerHangupFailed, .unknown:
            return false
        }
    }

    private static func title(for reason: VoiceSessionFailureReason) -> String {
        switch reason {
        case .micDenied:    return "Microphone access needed"
        case .keyFetch(let failure):
            switch failure {
            case .unauthorized:         return "Sign-in required"
            case .subscriptionRequired: return "Pro required"
            case .serviceUnavailable:   return "Voice unavailable"
            case .network:              return "No connection"
            case .unknown:              return "Couldn't start the session"
            }
        case .sessionStart(let failure):
            switch failure {
            case .alreadyActive:        return "Voice chat already active"
            case .insufficientCredits:  return "Trial credits used up"
            case .mintFailed:           return "Voice unavailable"
            case .unauthorized:         return "Sign-in required"
            case .serviceUnavailable:   return "Voice unavailable"
            case .network:              return "No connection"
            case .unknown:              return "Couldn't start the session"
            }
        case .callRegistration:
            return "Couldn't confirm the connection"
        case .connect:      return "Couldn't connect"
        case .networkLost:  return "Connection lost"
        case .audioSession: return "Audio setup failed"
        case .sessionTerminated(let reason):
            return Self.sessionTerminatedTitle(for: reason)
        case .unknown:      return "Something went wrong"
        }
    }

    private static func sessionTerminatedTitle(for reason: ControlTerminalReason) -> String {
        switch reason {
        case .voiceSessionTimeCap:          return "Time limit reached"
        case .trialCreditsExhausted:        return "Trial credits used up"
        case .planVoiceAllowanceExhausted:  return "Voice Chat allowance used up"
        case .registrationTimeout:          return "Couldn't confirm the connection"
        case .providerHangupFailed:         return "Voice chat ended"
        case .unknown:                      return "Voice chat ended"
        }
    }

    private static func bodyCopy(for reason: VoiceSessionFailureReason) -> String {
        switch reason {
        case .micDenied:
            return "Allow microphone access in Settings to talk with the AI."
        case .keyFetch(let failure):
            switch failure {
            case .unauthorized:
                return "Your session expired. Sign in again to use voice chat."
            case .subscriptionRequired:
                return "Voice chat is a Pro feature."
            case .serviceUnavailable:
                return "The voice service is temporarily unavailable. Please try again soon."
            case .network:
                return "Check your internet connection and try again."
            case .unknown(let detail):
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .sessionStart(let failure):
            switch failure {
            case .alreadyActive:
                return "You already have a voice session running. Close it before starting another."
            case .insufficientCredits:
                return "You've used all 100 trial voice credits. Upgrade to keep using voice chat."
            case .mintFailed:
                return "The voice service couldn't start your session. Try again in a moment."
            case .unauthorized:
                return "Your session expired. Sign in again to use voice chat."
            case .serviceUnavailable:
                return "The voice service is temporarily unavailable. Please try again soon."
            case .network:
                return "Check your internet connection and try again."
            case .unknown(let detail):
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .callRegistration(let failure):
            switch failure {
            case .missingCallId, .invalidBody, .sessionIdMismatch, .nonceInvalid:
                return "Couldn't confirm the voice connection. Please try again."
            case .noActiveSession:
                return "That voice session is no longer active. Start a new one."
            case .callAlreadyRegistered, .nonceReplayed:
                return "This voice connection was already confirmed. Please try again."
            case .unauthorized:
                return "Your session expired. Sign in again to use voice chat."
            case .serviceUnavailable:
                return "The voice service is temporarily unavailable. Please try again soon."
            case .network:
                return "Check your internet connection and try again."
            case .unknown(let detail):
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .connect:
            return "The voice service couldn't be reached. Try again in a moment."
        case .networkLost:
            return "We lost the connection after a few retries. Try again."
        case .audioSession:
            return "We couldn't configure audio. Make sure no other app is using the microphone."
        case .sessionTerminated(let reason):
            return Self.sessionTerminatedBody(for: reason)
        case .unknown(let msg):
            return msg.isEmpty ? "An unexpected error occurred." : msg
        }
    }

    private static func sessionTerminatedBody(for reason: ControlTerminalReason) -> String {
        switch reason {
        case .voiceSessionTimeCap:
            return "This voice session reached its time limit."
        case .trialCreditsExhausted:
            return "You've used all 100 trial voice credits. Upgrade to keep using voice chat."
        case .planVoiceAllowanceExhausted:
            return "You've used your plan's Voice Chat time for this period."
        case .registrationTimeout:
            return "We couldn't confirm the voice connection in time. Please try again."
        case .providerHangupFailed:
            return "Voice chat ended unexpectedly. Please try again."
        case .unknown(let raw):
            return "Voice chat ended (\(raw))."
        }
    }
}
