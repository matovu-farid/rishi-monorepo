import SwiftUI
import RishiSync

/// Form-friendly wrapper that delegates to RishiSync's `SettingsSyncSection`.
///
/// `SettingsSyncSection` (Phase 7) already provides its own `Section` /
/// header — we re-export it under a name that matches the Settings-package
/// section-naming convention (`<Surface>SettingsSection` / `<Surface>Section`).
public struct SyncSettingsSection: View {

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
