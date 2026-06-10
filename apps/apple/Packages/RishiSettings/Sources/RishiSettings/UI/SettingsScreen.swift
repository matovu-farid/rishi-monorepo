import SwiftUI
import RishiUIKit
import RishiCore
import RishiReader
import RishiAudio
import RishiSync
import RishiBilling

/// SET-01 top-level Settings surface. `NavigationStack { Form { ... } }`
/// composes the 7 sections each as their own struct so unit tests can
/// render any subsection in isolation.
///
/// All section dependencies are passed in via init — the screen does not
/// reach into any environment / singleton. 11-06 wires it into the app
/// (replacing the legacy minimal SettingsSheet).
public struct SettingsScreen: View {

    public let user: User
    public let onSignOut: () async -> Void
    public let onDelete: () async throws -> Void
    public let onDeleted: () -> Void
    public let onDismiss: () -> Void
    public let onManageSubscription: () -> Void

    /// Reader app-wide defaults. Bindings are owned by AppDependencies in
    /// 11-06; this section only renders + edits them.
    @Binding public var readerTheme: ReaderTheme
    @Binding public var readerFontFamily: ReaderFontFamily

    /// Audio (TTS) deps. The picker persists changes through `audioStore`
    /// and notifies the parent via `onAudioChange`.
    public let audioUserId: UserID
    public let audioInitial: TTSSettings
    public let audioStore: any TTSSettingsStore
    public let onAudioChange: (TTSSettings) -> Void

    /// Sync deps — observable status + a closure to trigger a manual sync.
    public let syncStatus: SyncStatus
    public let onSyncNow: @Sendable () -> Void

    /// Telemetry store backing the Privacy toggle.
    public let telemetryStore: any TelemetryStore

    /// Entitlement resolver — defaults to `.production` (reads
    /// `ReaderAppEntitlementFlag.isGranted`); tests override.
    public let billingEntitlement: ReaderAppEntitlementFlag.Resolver

    @State private var showDeleteFlow = false

    public init(
        user: User,
        readerTheme: Binding<ReaderTheme>,
        readerFontFamily: Binding<ReaderFontFamily>,
        audioUserId: UserID,
        audioInitial: TTSSettings,
        audioStore: any TTSSettingsStore,
        onAudioChange: @escaping (TTSSettings) -> Void,
        syncStatus: SyncStatus,
        onSyncNow: @escaping @Sendable () -> Void,
        telemetryStore: any TelemetryStore,
        billingEntitlement: ReaderAppEntitlementFlag.Resolver = .production,
        onSignOut: @escaping () async -> Void,
        onDelete: @escaping () async throws -> Void,
        onDeleted: @escaping () -> Void,
        onManageSubscription: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.user = user
        self._readerTheme = readerTheme
        self._readerFontFamily = readerFontFamily
        self.audioUserId = audioUserId
        self.audioInitial = audioInitial
        self.audioStore = audioStore
        self.onAudioChange = onAudioChange
        self.syncStatus = syncStatus
        self.onSyncNow = onSyncNow
        self.telemetryStore = telemetryStore
        self.billingEntitlement = billingEntitlement
        self.onSignOut = onSignOut
        self.onDelete = onDelete
        self.onDeleted = onDeleted
        self.onManageSubscription = onManageSubscription
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Form {
                AccountSection(
                    user: user,
                    onSignOut: onSignOut,
                    onShowDeleteFlow: { showDeleteFlow = true }
                )
                BillingSection(
                    entitlement: billingEntitlement,
                    onManage: onManageSubscription
                )
                ReaderDefaultsSection(
                    defaultTheme: $readerTheme,
                    defaultFontFamily: $readerFontFamily
                )
                AudioSection(
                    userId: audioUserId,
                    initialSettings: audioInitial,
                    store: audioStore,
                    onChange: onAudioChange
                )
                SyncSettingsSection(status: syncStatus, onSyncNow: onSyncNow)
                TelemetrySection(store: telemetryStore)
                AboutSection()
            }
            .navigationTitle("Settings")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                        .accessibilityIdentifier("settings-done")
                }
            }
            .sheet(isPresented: $showDeleteFlow) {
                DeleteAccountFlow(
                    onDelete: onDelete,
                    onDeleted: {
                        showDeleteFlow = false
                        onDeleted()
                    },
                    onCancel: { showDeleteFlow = false }
                )
            }
        }
    }
}
