import Foundation

/// Pure date-arithmetic helper for rendering the "Last synced" string and
/// pending-count subline in `SyncStatusView` (SYNC-07).
///
/// All branches are tested under `en_US_POSIX` so the absolute-date fallback
/// is deterministic across CI runners. The relative branches return English
/// strings on purpose — SYNC-07's settings row is English-only in v1.
public enum SyncStatusFormatter {

    /// Render a "Last synced …" suffix string from a Date.
    ///
    /// Rules:
    ///   - `nil` → "Never synced"
    ///   - ≤ 60s ago (or future / clock skew) → "Just now"
    ///   - 1–59 minutes ago → "{N} minute(s) ago"
    ///   - 1–23 hours ago → "{N} hour(s) ago"
    ///   - ≥ 24h ago → absolute en_US_POSIX short date string ("M/d/yy")
    public static func relativeDescription(for date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never synced" }
        let elapsed = now.timeIntervalSince(date)
        // Negative deltas (date in the future, clock skew) → coerce to "Just now"
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return m == 1 ? "1 minute ago" : "\(m) minutes ago"
        }
        if elapsed < 86_400 {
            let h = Int(elapsed / 3600)
            return h == 1 ? "1 hour ago" : "\(h) hours ago"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yy"
        return formatter.string(from: date)
    }

    /// Render the pending-count subline.
    ///
    /// Rules:
    ///   - 0 → "No pending changes"
    ///   - 1 → "1 pending change" (singular)
    ///   - N → "{N} pending changes"
    public static func pendingCountDescription(_ count: Int) -> String {
        switch count {
        case ..<0, 0: return "No pending changes"
        case 1: return "1 pending change"
        default: return "\(count) pending changes"
        }
    }
}
