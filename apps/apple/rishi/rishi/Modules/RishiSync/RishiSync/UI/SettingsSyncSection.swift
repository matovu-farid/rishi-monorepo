import SwiftUI


/// Form `Section` wrapping `SyncStatusView` for embedding inside the app
/// Settings sheet. Header uses the `titleM` typography token so it reads as
/// a Form group header — matches the visual weight Apple's stock Form
/// section headers use without dragging an ad-hoc font.
public struct SettingsSyncSection: View {

    private let status: SyncStatus
    private let onSyncNow: @Sendable () -> Void

    public init(status: SyncStatus, onSyncNow: @escaping @Sendable () -> Void) {
        self.status = status
        self.onSyncNow = onSyncNow
    }

    public var body: some View {
        Section {
            SyncStatusView(status: status, onSyncNow: onSyncNow)
        } header: {
            Text("Sync")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview("Enabled") {
    Form {
        SettingsSyncSection(
            status: SyncStatus(
                lastSyncedAt: Date().addingTimeInterval(-120),
                pendingCount: 1,
                isRunning: false
            ),
            onSyncNow: {}
        )
    }
}

#Preview("Disabled") {
    Form {
        SettingsSyncSection(
            status: SyncStatus(
                lastSyncedAt: nil,
                pendingCount: 0,
                isRunning: false,
                lastError: "Sync disabled"
            ),
            onSyncNow: {}
        )
    }
}
