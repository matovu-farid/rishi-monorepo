@testable import rishi
import Testing
import Foundation


@Suite("SyncStatus snapshot")
struct SyncStatusTests {

    @Test("Initializer defaults are the empty surface")
    func emptyInitial() {
        let status = SyncStatus()
        let snap = status.snapshot()
        #expect(snap == SyncStatusSnapshot(lastSyncedAt: nil, pendingCount: 0, isRunning: false, lastError: nil))
    }

    @Test("apply(_:) replaces every field atomically")
    func applyReplacesEveryField() {
        let status = SyncStatus()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let new = SyncStatusSnapshot(lastSyncedAt: ts, pendingCount: 3, isRunning: true, lastError: "boom")
        status.apply(new)
        #expect(status.snapshot() == new)
    }
}
