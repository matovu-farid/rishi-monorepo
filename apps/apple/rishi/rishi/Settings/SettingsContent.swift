//
//  SettingsContent.swift
//  rishi
//
//  Phase 32 Plan 32-02 — shared settings content extracted from
//  `SettingsSheet`. Wraps `RishiSettings.SettingsScreen` (Account /
//  Subscription / Reader Defaults / Audio / Sync / Privacy / About
//  sections, incl. the Phase 31 Mac-only pdfViewMode picker) and owns the
//  initial-audio load `.task`.
//
//  Single source of truth for the ~17-param SettingsScreen wiring so BOTH
//  the iOS gear+sheet (`SettingsSheet`) and the Mac Settings WINDOW
//  (Plan 32-03) render byte-identical content from one wiring site.
//
//  Dismiss is driven by an EXPLICIT `onDismiss` closure (NOT the dismiss
//  environment value): the sheet passes `{ dismiss() }`, the Mac window
//  passes a window-close. This keeps the view usable outside a sheet
//  context where the dismiss environment is a no-op.
//

import SwiftUI
import RishiAudio
import RishiAuth
import RishiBilling
import RishiCore
import RishiSettings
import RishiSync

/// Shared content view wrapping `RishiSettings.SettingsScreen`. Hosted by
/// the iOS `SettingsSheet` and the Mac Settings window. Dismiss flows
/// through the injected `onDismiss` closure.
struct SettingsContent: View {

    let services: BootstrappedServices
    let user: User
    let onSignedOut: () -> Void
    /// EXPLICIT dismiss — replaces the dismiss environment so the same view
    /// works inside a sheet (`{ dismiss() }`) and a window (window-close).
    let onDismiss: () -> Void

    @State private var initialAudio: TTSSettings = .default
    @State private var audioLoaded = false

    var body: some View {
        Group {
            if audioLoaded {
                let defaults = services.readerDefaults
                let auth = services.authService
                let presenter = services.manageSubscriptionPresenter
                let sync = services.syncEngine
                SettingsScreen(
                    user: user,
                    readerTheme: Binding(
                        get: { defaults.theme },
                        set: { defaults.theme = $0 }
                    ),
                    readerFontFamily: Binding(
                        get: { defaults.fontFamily },
                        set: { defaults.fontFamily = $0 }
                    ),
                    pdfViewMode: Binding(
                        get: { defaults.pdfViewMode },
                        set: { defaults.pdfViewMode = $0 }
                    ),
                    audioUserId: user.id,
                    audioInitial: initialAudio,
                    audioStore: services.ttsSettingsStore,
                    onAudioChange: { _ in },
                    syncStatus: services.syncStatus,
                    // KEEP: Settings "Sync now" tap -> syncEngine actor await; no main IO.
                    onSyncNow: { Task { await sync.syncNow() } },
                    telemetryStore: services.telemetryStore,
                    footerDetectionStore: services.footerDetectionStore,
                    onSignOut: {
                        try? await auth.signOut()
                        await MainActor.run {
                            onDismiss()
                            onSignedOut()
                        }
                    },
                    onDelete: {
                        try await auth.deleteAccount()
                    },
                    onDeleted: {
                        onDismiss()
                        onSignedOut()
                    },
                    onManageSubscription: {
                        // KEEP: presenter.present() drives StoreKit's
                        // ManageSubscriptionsView which is a @MainActor sheet --
                        // explicit isolation is required for the SwiftUI surface.
                        Task { @MainActor in
                            await presenter.present()
                        }
                    },
                    onDismiss: { onDismiss() }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Load once per presentation; the AudioSection picker reads
            // `initialAudio` as its seed value, then persists subsequent
            // changes through `audioStore` itself.
            initialAudio = await services.ttsSettingsStore.load(userId: user.id)
            audioLoaded = true
        }
    }
}
