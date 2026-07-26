import SwiftUI


/// Pre-permission rationale screen presented BEFORE the system microphone
/// permission dialog appears. Mirrors the Info.plist
/// `NSMicrophoneUsageDescription` copy so users see a consistent rationale
/// in both the in-app prompt and the system alert.
///
/// `onAllow` is wired (by Plan 10-06) to trigger the system permission
/// prompt via ``RealtimeVoiceSession.start(...)``.
public struct VoicePermissionPrompt: View {
    private let onAllow: () -> Void
    private let onCancel: () -> Void

    public init(
        onAllow: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onAllow = onAllow
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "mic.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(RishiColor.accent)
                .accessibilityHidden(true)

            Text("Talk with the AI about your book")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
                .multilineTextAlignment(.center)

            // Mirrors the Info.plist NSMicrophoneUsageDescription copy.
            Text("Rishi uses your microphone to let you talk with the AI about the book you are reading. Audio is only sent during a conversation.")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)

            VStack(spacing: RishiSpacing.m) {
                Button(action: onAllow) {
                    Text("Allow microphone")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("voice.permission.allow")

                Button("Not now", action: onCancel)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("voice.permission.cancel")
            }
            .padding(.horizontal, RishiSpacing.l)
        }
        .padding(RishiSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.background.ignoresSafeArea())
    }
}

#Preview {
    VoicePermissionPrompt(onAllow: {}, onCancel: {})
}
