import SwiftUI
import RishiUIKit
#if canImport(UIKit)
import UIKit
#endif

/// Failure-state surface for a voice session.
///
/// Binds to a ``VoiceSessionFailureReason`` and presents:
///   * a destructive icon,
///   * a reason-specific title + body,
///   * a primary affordance ("Open Settings" for `.micDenied`, "Try again"
///     for all other reasons), and
///   * a Dismiss button.
///
/// `.micDenied` deep-links to the Settings app because — per Apple — there
/// is no in-app way to re-request the microphone after the user has denied
/// it (VOICE-08 reinforced).
public struct VoiceErrorView: View {
    public let reason: VoiceSessionFailureReason
    public let message: String?
    public let onRetry: () -> Void
    public let onDismiss: () -> Void

    public init(
        reason: VoiceSessionFailureReason,
        message: String? = nil,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.reason = reason
        self.message = message
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(RishiColor.danger)
                .accessibilityHidden(true)

            Text(title)
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(message ?? bodyCopy)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)

            VStack(spacing: RishiSpacing.m) {
                primaryButton
                Button("Dismiss", action: onDismiss)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("voice.error.dismiss")
            }
            .padding(.horizontal, RishiSpacing.l)
        }
        .padding(RishiSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch reason {
        case .micDenied:
            Button(action: openSettings) {
                Text("Open Settings")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .accessibilityIdentifier("voice.error.openSettings")
        default:
            Button(action: onRetry) {
                Text("Try again")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .accessibilityIdentifier("voice.error.retry")
        }
    }

    private var title: String {
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

    private var bodyCopy: String {
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

    private func openSettings() {
        #if canImport(UIKit) && (os(iOS) || targetEnvironment(macCatalyst))
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

#Preview("Mic denied") {
    VoiceErrorView(reason: .micDenied, onRetry: {}, onDismiss: {})
}

#Preview("Network lost") {
    VoiceErrorView(reason: .networkLost, onRetry: {}, onDismiss: {})
}

#Preview("Key fetch: sign-in required") {
    VoiceErrorView(reason: .keyFetch(.unauthorized), onRetry: {}, onDismiss: {})
}

#Preview("Key fetch: Pro required") {
    VoiceErrorView(reason: .keyFetch(.subscriptionRequired), onRetry: {}, onDismiss: {})
}

#Preview("Key fetch: service unavailable") {
    VoiceErrorView(reason: .keyFetch(.serviceUnavailable), onRetry: {}, onDismiss: {})
}

#Preview("Unknown") {
    VoiceErrorView(reason: .unknown("Realtime SDK fault"), onRetry: {}, onDismiss: {})
}
