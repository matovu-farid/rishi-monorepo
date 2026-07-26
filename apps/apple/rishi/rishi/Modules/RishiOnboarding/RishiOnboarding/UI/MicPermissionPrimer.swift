import SwiftUI


/// Pre-permission rationale shown BEFORE the system microphone dialog.
/// ONB-02. Mirrors Phase-10 `VoicePermissionPrompt` copy/structure so users
/// see a consistent rationale in both the in-app primer and the system alert.
///
/// `onAllow` is wired (by 11-06) to call
/// `AVAudioApplication.requestRecordPermission`.
struct MicPermissionPrimer: View {
    public let onAllow: () -> Void
    public let onSkip: () -> Void

    public init(
        onAllow: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.onAllow = onAllow
        self.onSkip = onSkip
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .belowContent) {
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

                Text("Rishi uses your microphone for voice chat with the AI. Audio is only sent while a conversation is active. You can change this anytime in Settings.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            VStack(spacing: RishiSpacing.m) {
                Button(action: onAllow) {
                    Text("Allow microphone")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                        .onboardingCTAWidth()
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("onboarding-mic-allow")

                Button("Not now", action: onSkip)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("onboarding-mic-skip")
            }
            .padding(.horizontal, RishiSpacing.l)
        }
    }
}

#Preview {
    MicPermissionPrimer(onAllow: {}, onSkip: {})
}
