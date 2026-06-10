import SwiftUI
import RishiUIKit

/// SYNC-07: surfaces last-sync time + pending count.
/// SYNC-08: surfaces a manual "Sync Now" affordance.
///
/// All visuals route through `RishiColor` / `RishiTypography` / `RishiSpacing`
/// tokens — no hex, no `.system(size:)`, no raw padding ints. The "Sync Now"
/// button calls `onSyncNow` (SyncEngine.syncNow is wired one level up in
/// `SettingsSheet`). The button is disabled while `status.isRunning` so the
/// user can't fan out concurrent syncs.
public struct SyncStatusView: View {

    @Bindable private var status: SyncStatus
    private let onSyncNow: @Sendable () -> Void

    public init(status: SyncStatus, onSyncNow: @escaping @Sendable () -> Void) {
        self._status = Bindable(status)
        self.onSyncNow = onSyncNow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.m) {
            row(
                label: "Last synced",
                value: SyncStatusFormatter.relativeDescription(for: status.lastSyncedAt)
            )
            row(
                label: "Pending",
                value: SyncStatusFormatter.pendingCountDescription(status.pendingCount)
            )

            Button(action: { onSyncNow() }) {
                HStack(spacing: RishiSpacing.s) {
                    if status.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(status.isRunning ? "Syncing…" : "Sync Now")
                        .font(RishiTypography.body)
                }
                .foregroundStyle(RishiColor.accent)
            }
            .disabled(status.isRunning)
            .accessibilityLabel(Text("Sync Now"))

            if let error = status.lastError, !error.isEmpty {
                Text(String(error.prefix(200)))
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
            }
        }
        .padding(RishiSpacing.m)
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
            Spacer()
            Text(value)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
        }
    }
}

#Preview("Idle") {
    SyncStatusView(
        status: SyncStatus(),
        onSyncNow: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

#Preview("Syncing") {
    SyncStatusView(
        status: SyncStatus(
            lastSyncedAt: Date().addingTimeInterval(-3600),
            pendingCount: 4,
            isRunning: true
        ),
        onSyncNow: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

#Preview("Error") {
    SyncStatusView(
        status: SyncStatus(
            lastSyncedAt: Date().addingTimeInterval(-7200),
            pendingCount: 2,
            isRunning: false,
            lastError: "Network unreachable"
        ),
        onSyncNow: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

#Preview("Last synced recently") {
    SyncStatusView(
        status: SyncStatus(
            lastSyncedAt: Date().addingTimeInterval(-30),
            pendingCount: 0,
            isRunning: false
        ),
        onSyncNow: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}
