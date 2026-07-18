import SwiftUI
import RishiUIKit

extension AIFeatureBlockReason {
    var title: String {
        switch self {
        case .trialExhausted:
            return "You're out of trial credits"
        case .subscriptionExpired:
            return "Your subscription has expired"
        case .narrationAllowanceExhausted:
            return "You've used this month's narration time"
        case .voiceChatAllowanceExhausted:
            return "You've used this month's Voice Chat time"
        }
    }

    var message: String {
        switch self {
        case .trialExhausted:
            return "Upgrade to Rishi Reader or Rishi Voice to keep listening. Your books stay fully readable either way."
        case .subscriptionExpired:
            return "Renew your subscription to keep using Natural AI narration and Voice Chat. Your books stay fully readable either way."
        case .narrationAllowanceExhausted:
            return "Narration resets next period, or upgrade to Rishi Voice for more. Reading stays available."
        case .voiceChatAllowanceExhausted:
            return "Voice Chat resets next period, or upgrade to Rishi Voice for more. Reading stays available."
        }
    }
}

/// Non-blocking upgrade prompt shown at the moment an AI feature is
/// intercepted (TTS play button, Voice Chat start) — never a full-screen,
/// app-wide block. Present as a `.sheet(item:)`; dismissing it always leaves
/// the reader fully usable.
public struct AIFeatureUpgradePrompt: View {
    public let reason: AIFeatureBlockReason
    public let onUpgrade: () -> Void
    public let onDismiss: () -> Void

    public init(
        reason: AIFeatureBlockReason,
        onUpgrade: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.reason = reason
        self.onUpgrade = onUpgrade
        self.onDismiss = onDismiss
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text(reason.title)
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(reason.message)
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            VStack(spacing: RishiSpacing.s) {
                Button(action: onUpgrade) {
                    Text("See plans")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("ai-upgrade-prompt-see-plans")

                Button("Not now", action: onDismiss)
                    .accessibilityIdentifier("ai-upgrade-prompt-dismiss")
            }
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
        }
    }
}

#Preview("Trial exhausted") {
    AIFeatureUpgradePrompt(reason: .trialExhausted, onUpgrade: {}, onDismiss: {})
}

#Preview("Voice Chat allowance exhausted") {
    AIFeatureUpgradePrompt(reason: .voiceChatAllowanceExhausted, onUpgrade: {}, onDismiss: {})
}
