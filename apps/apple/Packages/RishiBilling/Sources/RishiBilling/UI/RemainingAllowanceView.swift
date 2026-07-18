import SwiftUI
import RishiUIKit
import RishiCore

/// Renders the account's remaining AI allowance. Trial users see a credit
/// counter; Reader/Voice users see human-readable narration + Voice Chat time
/// remaining and their period reset date — **never** a raw credit number
/// (spec: "Never expose paid internal credits"). Warning color/icon appears
/// below the documented thresholds in `AllowanceWarningThreshold`.
public struct RemainingAllowanceView: View {
    public let snapshot: EntitlementSnapshot

    public init(snapshot: EntitlementSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.xs) {
            switch snapshot {
            case .trialActive(let remainingCredits):
                AllowanceRow(
                    iconName: "bolt.fill",
                    text: AllowanceFormatter.creditsDescription(remainingCredits),
                    isLow: AllowanceWarningThreshold.isLowTrialCredits(remainingCredits)
                )
            case .readerActive(let period):
                planRows(
                    period: period,
                    narrationTotal: PlanAllowance.readerNarrationSeconds,
                    voiceChatTotal: PlanAllowance.readerVoiceChatSeconds
                )
            case .voiceActive(let period):
                planRows(
                    period: period,
                    narrationTotal: PlanAllowance.voiceNarrationSeconds,
                    voiceChatTotal: PlanAllowance.voiceVoiceChatSeconds
                )
            case .trialExhausted:
                AllowanceRow(
                    iconName: "exclamationmark.circle.fill",
                    text: "Trial credits used up",
                    isLow: true
                )
            case .subscriptionExpired:
                AllowanceRow(
                    iconName: "exclamationmark.circle.fill",
                    text: "Subscription expired",
                    isLow: true
                )
            }

            if let periodEnd = snapshot.periodEnd {
                Text(AllowanceFormatter.resetDateDescription(periodEnd))
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textMuted)
            }
        }
    }

    private func planRows(
        period: EntitlementSnapshot.PaidPeriod,
        narrationTotal: Int,
        voiceChatTotal: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: RishiSpacing.xs) {
            AllowanceRow(
                iconName: "waveform",
                text: "\(AllowanceFormatter.timeRemainingDescription(seconds: period.remainingNarrationSeconds)) narration left",
                isLow: AllowanceWarningThreshold.isLowRemaining(period.remainingNarrationSeconds, of: narrationTotal)
            )
            AllowanceRow(
                iconName: "mic.fill",
                text: "\(AllowanceFormatter.timeRemainingDescription(seconds: period.remainingVoiceChatSeconds)) Voice Chat left",
                isLow: AllowanceWarningThreshold.isLowRemaining(period.remainingVoiceChatSeconds, of: voiceChatTotal)
            )
        }
    }
}

/// One allowance line: icon + text, colored `RishiColor.warning` when `isLow`.
/// Extracted to a standalone type because `RemainingAllowanceView` reuses it
/// three times (credits / narration / Voice Chat).
private struct AllowanceRow: View {
    let iconName: String
    let text: String
    let isLow: Bool

    var body: some View {
        HStack(spacing: RishiSpacing.s) {
            Image(systemName: iconName)
                .foregroundStyle(isLow ? RishiColor.warning : RishiColor.accent)
            Text(text)
                .font(RishiTypography.body)
                .foregroundStyle(isLow ? RishiColor.warning : RishiColor.textPrimary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Trial — healthy") {
    Form {
        RemainingAllowanceView(snapshot: .trialActive(remainingCredits: 82))
    }
}

#Preview("Trial — low") {
    Form {
        RemainingAllowanceView(snapshot: .trialActive(remainingCredits: 3))
    }
}

#Preview("Reader — low narration") {
    Form {
        RemainingAllowanceView(snapshot: .readerActive(.init(
            periodEndMs: Int64(Date().addingTimeInterval(86_400 * 12).timeIntervalSince1970 * 1000),
            remainingNarrationSeconds: 300,
            remainingVoiceChatSeconds: 480
        )))
    }
}

#Preview("Trial exhausted") {
    Form {
        RemainingAllowanceView(snapshot: .trialExhausted)
    }
}
