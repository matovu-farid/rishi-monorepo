import Foundation
import RishiCore

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
/// `.paidNarrationExhaustion` / `.paidVoiceChatExhaustion` (plan 12) — this
/// type exists separately only to carry the fourth, feature-independent
/// `.subscriptionExpired` case and UI-facing copy (see `AIFeatureUpgradePrompt`),
/// not because the underlying signal differs.
public enum AIFeatureBlockReason: String, Sendable, Equatable, Identifiable {
    case trialExhausted
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
            return remainingCredits <= 0 ? .trialExhausted : nil

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
