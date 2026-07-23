import SwiftUI
import RishiUIKit

/// One-time, per-account explainer shown after first sign-in, before any
/// entitlement UI. Persistence: `TrialOnboardingState` (per-account, not
/// per-device — see `Storage/TrialOnboardingState.swift`).
///
/// Deliberately separate from `OnboardingFlowView`'s device-scoped wizard
/// stages: this screen depends on knowing *which account* signed in, so it
/// is triggered from the app shell (`RootView`) once `CurrentUserBox` has a
/// signed-in user, not from `OnboardingCoordinator`.
public struct NoCardTrialScreen: View {
    public let onGotIt: () -> Void

    public init(onGotIt: @escaping () -> Void) {
        self.onGotIt = onGotIt
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "gift.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text("Try Rishi's AI features free")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: RishiSpacing.m) {
                    bullet(
                        icon: "creditcard.slash.fill",
                        text: "No credit card required"
                    )
                    bullet(
                        icon: "bolt.fill",
                        text: "300 free credits to start — they never expire"
                    )
                    bullet(
                        icon: "waveform",
                        text: "Credits cover Natural AI narration and Voice Chat. Reading your books is always free."
                    )
                }
                .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            Button(action: onGotIt) {
                Text("Got it")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
            .accessibilityIdentifier("onboarding-no-card-trial-gotit")
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: RishiSpacing.s) {
            Image(systemName: icon)
                .foregroundStyle(RishiColor.accent)
                .frame(width: 20)
            Text(text)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview {
    NoCardTrialScreen(onGotIt: {})
}
