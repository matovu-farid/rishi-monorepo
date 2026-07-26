import SwiftUI


/// Form-friendly wrapper that delegates to RishiSync's `SettingsSyncSection`.
///
/// `SettingsSyncSection` (Phase 7) already provides its own `Section` /
/// header — we re-export it under a name that matches the Settings-package
/// section-naming convention (`<Surface>SettingsSection` / `<Surface>Section`).
struct SyncSettingsSection: View {

    public let status: SyncStatus
    public let onSyncNow: @Sendable () -> Void

    public init(status: SyncStatus, onSyncNow: @escaping @Sendable () -> Void) {
        self.status = status
        self.onSyncNow = onSyncNow
    }

    public var body: some View {
        SettingsSyncSection(status: status, onSyncNow: onSyncNow)
    }
}

#Preview("Idle") {
    Form {
        SyncSettingsSection(
            status: SyncStatus(
                lastSyncedAt: Date().addingTimeInterval(-120),
                pendingCount: 0,
                isRunning: false
            ),
            onSyncNow: {}
        )
    }
}

#Preview("Pending") {
    Form {
        SyncSettingsSection(
            status: SyncStatus(
                lastSyncedAt: Date().addingTimeInterval(-3600),
                pendingCount: 4,
                isRunning: true
            ),
            onSyncNow: {}
        )
    }
}
