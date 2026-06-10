//
//  SettingsSheet.swift
//  rishi
//
//  Phase 11 Plan 11-06 — replaces the Phase-7 minimal SettingsSheet with
//  the full `RishiSettings.SettingsScreen` (Account / Subscription /
//  Reader Defaults / Audio / Sync / Privacy / About sections).
//
//  Composition lives in `AppDependencies.makeSettingsScreen(...)` so this
//  view only owns:
//    1. Loading the initial `TTSSettings` for the Audio section picker.
//    2. Dismiss + sign-out + delete-account dispatch back to RootView.
//

import SwiftUI
import RishiAudio
import RishiCore
import RishiSettings

/// Sheet wrapping `RishiSettings.SettingsScreen`. Presented from the Library
/// toolbar gear button.
struct SettingsSheet: View {

    let dependencies: AppDependencies
    let user: User
    let onSignedOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var initialAudio: TTSSettings = .default
    @State private var audioLoaded = false

    var body: some View {
        Group {
            if audioLoaded {
                dependencies.makeSettingsScreen(
                    user: user,
                    audioInitial: initialAudio,
                    onDismiss: { dismiss() },
                    onSignedOut: {
                        dismiss()
                        onSignedOut()
                    },
                    onAccountDeleted: {
                        dismiss()
                        onSignedOut()
                    }
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
            initialAudio = await dependencies.ttsSettingsStore.load(userId: user.id)
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
