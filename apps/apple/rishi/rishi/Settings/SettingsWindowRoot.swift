//
//  SettingsWindowRoot.swift
//  rishi
//
//  Phase 32 Plan 32-03 — root view of the dedicated Mac Settings WINDOW
//  (the second `WindowGroup(id: "settings")` scene declared in rishiApp).
//  Mac-Catalyst-only: iOS keeps the in-app gear + sheet (Plan 32-04 removes
//  the Mac gear, not this wave).
//
//  Mirrors RootView's `deps.services` nil-guard (ProgressView until bootstrap
//  completes) so a Cmd+, on a cold launch shows a spinner rather than a blank
//  window. Sources the current `User` ONCE from the SAME authService RootView
//  probes (Open Q2 — do NOT duplicate RootView's probe logic), then presents
//  the shared `SettingsContent` from Plan 32-02.
//
//  Single-instance backstop (Pitfall 2): flips the shared
//  `deps.settingsWindowPresenter` flag on appear/disappear. The Cmd+,
//  dispatcher (`MacCommandDispatchModifier`) reads `shouldOpen` and only calls
//  `openWindow(id:)` when the window is not already open.
//

#if targetEnvironment(macCatalyst)

import SwiftUI
import RishiCore

struct SettingsWindowRoot: View {

    @Environment(\.appDependencies) private var deps
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var user: User? = nil

    var body: some View {
        Group {
            if let deps, let services = deps.services, let user {
                SettingsContent(
                    services: services,
                    user: user,
                    onSignedOut: {
                        dismissWindow(id: "settings")
                        deps.settingsWindowPresenter.markClosed()
                    },
                    onDismiss: {
                        dismissWindow(id: "settings")
                    }
                )
                .onAppear {
                    deps.settingsWindowPresenter.markOpened()
                    SettingsMacWindowSizing.apply()
                }
                .onDisappear {
                    deps.settingsWindowPresenter.markClosed()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading Settings")
            }
        }
        .task {
            // Open Q2 — source the User from the SAME authService RootView
            // probes (`auth.currentUser`), reading the live services rather
            // than re-running RootView's bootstrap. Resolved once per window.
            user = await deps?.services?.authService.currentUser
        }
    }
}

#endif
