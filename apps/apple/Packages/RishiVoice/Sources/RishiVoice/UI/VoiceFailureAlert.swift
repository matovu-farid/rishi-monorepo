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
        /// Restart the failed session (every non-`.micDenied` reason).
        case retry
    }

    public let title: String
    public let message: String
    public let primaryAction: PrimaryAction

    public init(reason: VoiceSessionFailureReason, message: String?) {
        self.title = Self.title(for: reason)
        self.message = message ?? Self.bodyCopy(for: reason)
        self.primaryAction = (reason == .micDenied) ? .openSettings : .retry
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
        case .connect:      return "Couldn't connect"
        case .networkLost:  return "Connection lost"
        case .audioSession: return "Audio setup failed"
        case .unknown:      return "Something went wrong"
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
        case .connect:
            return "The voice service couldn't be reached. Try again in a moment."
        case .networkLost:
            return "We lost the connection after a few retries. Try again."
        case .audioSession:
            return "We couldn't configure audio. Make sure no other app is using the microphone."
        case .unknown(let msg):
            return msg.isEmpty ? "An unexpected error occurred." : msg
        }
    }
}
