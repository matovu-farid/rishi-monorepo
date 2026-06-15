//
//  SettingsSheet.swift
//  rishi
//
//  Phase 11 Plan 11-06 — replaces the Phase-7 minimal SettingsSheet with
//  the full `RishiSettings.SettingsScreen` (Account / Subscription /
//  Reader Defaults / Audio / Sync / Privacy / About sections).
//
//  Receives a `BootstrappedServices` value and constructs `SettingsScreen`
//  inline. Owns:
//    1. Loading the initial `TTSSettings` for the Audio section picker.
//    2. Dismiss + sign-out + delete-account dispatch back to RootView.
//

import SwiftUI
import RishiAudio
import RishiAuth
import RishiBilling
import RishiCore
import RishiSettings
import RishiSync

/// Sheet wrapping `RishiSettings.SettingsScreen`. Presented from the Library
/// toolbar gear button.
struct SettingsSheet: View {

    let services: BootstrappedServices
    let user: User
    let onSignedOut: () -> Void

    @Environment(\.dismiss) private var dismiss
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
                            dismiss()
                            onSignedOut()
                        }
                    },
                    onDelete: {
                        try await auth.deleteAccount()
                    },
                    onDeleted: {
                        dismiss()
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
                    onDismiss: { dismiss() }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Load once per sheet presentation; the AudioSection picker reads
            // `initialAudio` as its seed value, then persists subsequent
            // changes through `audioStore` itself.
            initialAudio = await services.ttsSettingsStore.load(userId: user.id)
            audioLoaded = true
        }
    }
}

#Preview("Default") {
    PreviewPlaceholder(
        title: "Settings",
        subtitle: "Account, Subscription, Reader Defaults, Audio, Sync, Privacy.",
        variant: "Default"
    )
}

#Preview("Dark") {
    PreviewPlaceholder(
        title: "Settings",
        subtitle: "Account, Subscription, Reader Defaults, Audio, Sync, Privacy.",
        variant: "Dark"
    )
    .preferredColorScheme(.dark)
}
