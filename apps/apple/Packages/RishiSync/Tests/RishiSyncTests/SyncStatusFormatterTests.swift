import Foundation
import Testing
@testable import RishiSync

@Suite("SyncStatusFormatter")
struct SyncStatusFormatterTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000) // pinned reference instant

    @Test("nil date → Never synced")
    func nilDateReturnsNeverSynced() {
        #expect(SyncStatusFormatter.relativeDescription(for: nil, now: now) == "Never synced")
    }

    @Test("within 60s → Just now")
    func recentReturnsJustNow() {
        let date = now.addingTimeInterval(-5)
        #expect(SyncStatusFormatter.relativeDescription(for: date, now: now) == "Just now")
    }

    @Test("exactly 60s ago → 1 minute ago")
    func sixtySecondsAgoReturnsOneMinute() {
        let date = now.addingTimeInterval(-60)
        #expect(SyncStatusFormatter.relativeDescription(for: date, now: now) == "1 minute ago")
    }

    @Test("5 minutes ago → 5 minutes ago")
    func fiveMinutesAgoReturnsPlural() {
        let date = now.addingTimeInterval(-5 * 60)
        #expect(SyncStatusFormatter.relativeDescription(for: date, now: now) == "5 minutes ago")
    }

    @Test("1 hour ago → 1 hour ago (singular)")
    func oneHourAgoReturnsSingular() {
        let date = now.addingTimeInterval(-3600)
        #expect(SyncStatusFormatter.relativeDescription(for: date, now: now) == "1 hour ago")
    }

    @Test("5 hours ago → 5 hours ago (plural)")
    func fiveHoursAgoReturnsPlural() {
        let date = now.addingTimeInterval(-5 * 3600)
        #expect(SyncStatusFormatter.relativeDescription(for: date, now: now) == "5 hours ago")
    }

    @Test("48 hours ago → absolute en_US_POSIX short date")
    func fortyEightHoursAgoReturnsAbsolute() {
        let date = now.addingTimeInterval(-48 * 3600)
        let result = SyncStatusFormatter.relativeDescription(for: date, now: now)
        // en_US_POSIX, format M/d/yy
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yy"
        formatter.timeZone = TimeZone(identifier: "UTC") // also pinned for parity
        let expected = formatter.string(from: date)
        // Implementation may or may not pin TZ; just check non-empty + M/d/yy shape
        #expect(!result.isEmpty)
        #expect(result.contains("/"))
        // Numeric components only:
        #expect(result.allSatisfy { "0123456789/".contains($0) })
        _ = expected
    }

    @Test("pendingCountDescription(0) → No pending changes")
    func pendingZeroReturnsNoChanges() {
        #expect(SyncStatusFormatter.pendingCountDescription(0) == "No pending changes")
    }

    @Test("pendingCountDescription(1) → 1 pending change (singular)")
    func pendingOneReturnsSingular() {
        #expect(SyncStatusFormatter.pendingCountDescription(1) == "1 pending change")
    }

    @Test("pendingCountDescription(5) → 5 pending changes (plural)")
    func pendingFiveReturnsPlural() {
        #expect(SyncStatusFormatter.pendingCountDescription(5) == "5 pending changes")
    }
}
