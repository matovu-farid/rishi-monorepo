import Foundation

/// Per-plan monthly allowance totals (pricing table in
/// `2026-07-17-no-card-credit-trial-design.md`). Used only to compute the
/// "less than 10% remaining" warning threshold — `EntitlementSnapshot.PaidPeriod`
/// carries remaining seconds, not the period total.
enum PlanAllowance {
    static let readerNarrationSeconds = 2 * 60 * 60
    static let readerVoiceChatSeconds = 10 * 60
    static let voiceNarrationSeconds = 4 * 60 * 60
    static let voiceVoiceChatSeconds = 30 * 60
}

/// Documented warning thresholds. See Task 4 rationale in
/// `2026-07-17-no-card-onboarding-allowance-ui.md` for why these exact
/// numbers were chosen.
enum AllowanceWarningThreshold {
    /// Trial credits: warn below this absolute count.
    static let lowTrialCreditsFloor = 5

    /// Paid narration/Voice Chat allowances: warn below this fraction of the
    /// plan's period total.
    static let lowRemainingFraction = 0.10

    static func isLowTrialCredits(_ remaining: Int) -> Bool {
        remaining < lowTrialCreditsFloor
    }

    static func isLowRemaining(_ remaining: Int, of total: Int) -> Bool {
        guard total > 0 else { return false }
        return Double(remaining) / Double(total) < lowRemainingFraction
    }
}

/// Pure, deterministic formatting. Mirrors `SyncStatusFormatter`'s shape
/// (`RishiSync/Sources/RishiSync/UI/SyncStatusFormatter.swift`) — a plain
/// namespace of `static func`s pinned to `en_US_POSIX` so output does not
/// depend on the runtime locale.
enum AllowanceFormatter {

    /// "1 credit remaining" / "42 credits remaining". Never called for a
    /// paid-plan user — see `RemainingAllowanceView`.
    static func creditsDescription(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 credit remaining" : "\(clamped) credits remaining"
    }

    /// "1h 24m" / "45m" / "0m". Deliberately coarse (no seconds) — matches
    /// the spec's "human-readable time" requirement for paid users.
    static func timeRemainingDescription(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    /// "Resets Aug 14" — the period-reset date shown to paid users.
    static func resetDateDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "Resets \(formatter.string(from: date))"
    }
}
