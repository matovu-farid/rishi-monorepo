import Foundation


/// The two AI features that can be gated at their entry point. Deliberately
/// does not include "reading" — core reading is never gated (spec: "core
/// reading remains available" at both `trialExhausted` and
/// `subscriptionExpired`).
public enum AIFeature: Sendable, Equatable {
    case narration
    case voiceChat
}

/// Why an AI-feature tap was intercepted. `Identifiable` so it can drive
/// `.sheet(item:)` directly (see `AIFeatureUpgradePrompt`, `ReaderDestination`,
/// `ReaderVoiceEntry`).
///
/// `.trialExhausted` / `.narrationAllowanceExhausted` / `.voiceChatAllowanceExhausted`
/// correspond 1:1 to `EntitlementClientState.trialExhaustion` /
/// `.paidNarrationExhaustion` / `.paidVoiceChatExhaustion` (plan 12). The
/// remaining cases provide UI-specific reasons for an expired subscription
/// and for Voice Chat's two-credit minimum.
public enum AIFeatureBlockReason: String, Sendable, Equatable, Identifiable {
    case trialExhausted
    case insufficientTrialCreditsForVoiceChat
    case subscriptionExpired
    case narrationAllowanceExhausted
    case voiceChatAllowanceExhausted

    public var id: String { rawValue }
}

public extension EntitlementSnapshot {

    /// Pure, synchronous, side-effect-free access check for one AI feature.
    /// Returns `nil` when the feature should proceed, or the reason to show
    /// instead of starting it.
    ///
    /// This is the exact function `voice-session-flow-wiring` should call
    /// before opening a Voice Chat session:
    /// `entitlementSnapshotStore.snapshot.blockReason(for: .voiceChat)`.
    func blockReason(for feature: AIFeature) -> AIFeatureBlockReason? {
        switch self {
        case .trialActive(let remainingCredits):
            switch feature {
            case .narration:
                return remainingCredits < 1 ? .trialExhausted : nil
            case .voiceChat:
                if remainingCredits < 1 { return .trialExhausted }
                return remainingCredits < 2 ? .insufficientTrialCreditsForVoiceChat : nil
            }

        case .trialExhausted:
            return .trialExhausted

        case .subscriptionExpired:
            return .subscriptionExpired

        case .readerActive(let period), .voiceActive(let period):
            switch feature {
            case .narration:
                return period.remainingNarrationSeconds <= 0 ? .narrationAllowanceExhausted : nil
            case .voiceChat:
                return period.remainingVoiceChatSeconds <= 0 ? .voiceChatAllowanceExhausted : nil
            }
        }
    }
}
