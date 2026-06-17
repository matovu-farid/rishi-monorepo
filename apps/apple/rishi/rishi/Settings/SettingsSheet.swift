//
//  SettingsSheet.swift
//  rishi
//
//  Phase 11 Plan 11-06 — full `RishiSettings.SettingsScreen` settings.
//  Phase 32 Plan 32-02 — slimmed to a thin iOS wrapper. The SettingsScreen
//  wiring + audio-load now live in the shared `SettingsContent` view (reused
//  by the Mac Settings window). This sheet just hosts `SettingsContent` and
//  bridges its explicit `onDismiss` to the sheet's dismiss environment.
//

import SwiftUI
import RishiCore

/// iOS sheet wrapping the shared `SettingsContent`. Presented from the
/// Library toolbar gear button. The dismiss environment is valid inside a
/// sheet, so it is bridged into `SettingsContent` via `onDismiss`.
struct SettingsSheet: View {

    let services: BootstrappedServices
    let user: User
    let onSignedOut: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsContent(
            services: services,
            user: user,
            onSignedOut: onSignedOut,
            onDismiss: { dismiss() }
        )
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
