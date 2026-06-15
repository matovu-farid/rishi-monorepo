//
//  RootView.swift
//  rishi
//
//  Thin auth-switch shell. Branches on `authProbeComplete` / `currentUser`
//  to show a loading background, `SignedInView`, or `SignedOutView`.
//  Owns the `@SceneStorage` cells (passed as bindings to `SignedInView`) and
//  the first-launch onboarding cover which spans both auth states.
//
//  All signed-in composition, helper types, and reader infrastructure live
//  in `SignedInView.swift`. `OnboardingHost` lives in
//  `Onboarding/OnboardingHost.swift`.
//

import SwiftUI
import RishiCore
import RishiAuth
import RishiBilling

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps

    // MARK: - Phase 12 Plan 12-02 — @SceneStorage cells (MAC-05)
    //
    // SwiftUI restores `@SceneStorage` per scene-session. Owned here so the
    // cells survive the signed-in/signed-out branch swap and are passed to
    // SignedInView as bindings.
    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw: String = ""
    @SceneStorage(RishiSceneState.openBookIdKey)  private var openBookIdRaw: String = ""

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false
    /// Phase 21 perf — gate the signed-in/signed-out branch on the FIRST
    /// completion of the auth probe so a cold launch with a valid keychain
    /// session doesn't flash the sign-in UI.
    @State private var authProbeComplete = false

    // MARK: - Phase 11 (Onboarding) state
    //
    // `showOnboarding` is set to !state.hasCompletedOnboarding by the
    // bootstrap task. Presented over both the signed-in AND signed-out
    // branches so first-run users see the welcome screen before auth.
    @State private var showOnboarding = false

    var body: some View {
        // Phase 19 plan 19-01 (F-P0-01) — gate the real UI on bootstrap
        // completion. `deps.services` flips non-nil after the off-main
        // factory finishes. SwiftUI re-evaluates `body` because `deps`
        // is `@State`-held and `services` is a `private(set) var` on a
        // `@MainActor` class. Until then we show a ProgressView so first
        // frame paints immediately instead of the user staring at a
        // black/launchscreen-frozen window for hundreds of ms.
        if let deps, deps.services != nil {
            realBody(deps: deps)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading Rishi")
        }
    }

    @ViewBuilder
    private func realBody(deps: AppDependencies) -> some View {
        // Phase 19 plan 19-01 — re-inject object-typed environments that
        // used to live on the `WindowGroup` root. They can only be
        // installed once `deps.services` is non-nil, which the outer
        // `body` guard guarantees here. `ManageSubscriptionRow`
        // (presented from `SettingsSheet`) reads
        // `@Environment(ManageSubscriptionPresenter.self)`.
        realBodyContent(deps: deps)
            .environment(deps.manageSubscriptionPresenter)
    }

    @ViewBuilder
    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {
            if !authProbeComplete {
                // Phase 21 perf — first paint while the keychain probe runs.
                // Painting `signedOutView` here would flash sign-in UI for
                // users who ARE signed in (the `.task` below hasn't resolved
                // yet on the first body evaluation). A blank background
                // matches the launch screen color so the transition into the
                // library / signed-out branch is seamless.
                #if canImport(UIKit)
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                #else
                Color.clear
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                #endif
            } else if let user = currentUser {
                // Entire signed-in composition lives in SignedInView.
                // It owns the library tab, reader destinations, all
                // signed-in sheets, read-aloud controls, deep-link
                // wiring, scene restore, and Mac-command dispatch.
                SignedInView(
                    services: deps.services!,
                    user: user,
                    selectedTabRaw: $selectedTabRaw,
                    openBookIdRaw: $openBookIdRaw,
                    onSignedOut: { currentUser = nil },
                    onCacheUserId: { [deps] id in deps.cachedUserId = id }
                )
            } else {
                signedOutView
            }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            // Phase 21 perf — order matters: probe the keychain FIRST and
            // flip `authProbeComplete` so the body swaps from the blank
            // loading background straight into the library (or sign-in)
            // before any of the secondary bootstrap awaits run. Entitlement
            // refresh + onboarding flag read both touch the worker / disk
            // and would otherwise extend the loading-background window for
            // signed-in users who don't need either result before first paint.
            let probedUser = await auth?.currentUser
            currentUser = probedUser
            authProbeComplete = true
            // Phase 11 — gate the first-launch onboarding cover on the
            // persisted flag. Refresh entitlement only when the user has
            // already signed in (signed-out users have nothing to fetch).
            // Phase 19 plan 19-01 — deps is now non-optional inside
            // realBody (services already verified).
            //
            // Phase 21 perf — `hasCompletedOnboarding()` (UserDefaults
            // read on a MainActor-isolated store) and
            // `entitlementService.refresh()` (worker round-trip on an
            // actor) are independent of each other. Fan them out with
            // `async let` so the network probe overlaps with the local
            // onboarding flag read instead of stalling behind it.
            if probedUser != nil {
                async let completedAsync = deps.onboardingState.hasCompletedOnboarding()
                async let entitlementAsync = deps.entitlementService.refresh()
                let (completed, _) = await (completedAsync, entitlementAsync)
                showOnboarding = !completed
            } else {
                let completed = await deps.onboardingState.hasCompletedOnboarding()
                showOnboarding = !completed
            }
        }
        // Phase 11 — first-launch onboarding cover. Presented over the
        // signed-in OR signed-out path because we want the welcome screen
        // even before the user has authenticated.
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingHost(
                services: deps.services!,
                onCompleted: { showOnboarding = false }
            )
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            OnboardingHost(
                services: deps.services!,
                onCompleted: { showOnboarding = false }
            )
        }
        #endif
    }

    @ViewBuilder private var signedOutView: some View {
        // Quick-SXI: replaced Phase-3 debug stub. SignedOutView pulls
        // (any AuthService)? from @Environment(\.rishiAuthService) — same
        // wire rishiApp already injects in `.environment(\.rishiAuthService,
        // deps.authServiceForEnvironment)`. Both DEBUG and Release render
        // the same surface; DebugAuthView remains on disk under #if DEBUG
        // but is no longer reachable from this signed-out path.
        //
        // `onSignedIn`: SignedOutView's VM fires this exactly once after
        // the SIWA worker round-trip succeeds. We flip `currentUser` on
        // the main actor so RootView's body branches into the signed-in
        // tree on the next render, unmounting SignedOutView and
        // preventing the duplicate `auth.siwa.started` /
        // `/api/auth/sign-in/social` 403 that the previous fire-and-
        // forget bootstrap pattern allowed (see
        // `.planning/debug/resolved/siwa-double-fire-403.md`).
        //
        // We also refresh the entitlement snapshot here for parity with
        // the bootstrap branch in the outer `.task` so a freshly signed-
        // in user immediately has Pro state available.
        SignedOutView(onSignedIn: { user in
            currentUser = user
            if let deps {
                // KEEP: fire-and-forget actor hop — entitlementService is an
                // actor and refresh() awaits the worker on its own executor;
                // the outer Task only chains the await.
                Task { _ = await deps.entitlementService.refresh() }
            }
        })
    }
}

#Preview("Signed in") {
    PreviewPlaceholder(
        title: "Library",
        subtitle: "Signed-in users see the library, chats, and reader.",
        variant: "Signed in"
    )
}

#Preview("Signed out") {
    PreviewPlaceholder(
        title: "Sign in to Rishi",
        subtitle: "Signed-out users see the onboarding or debug auth surface.",
        variant: "Signed out"
    )
}

#Preview("Loading") {
    PreviewPlaceholder(
        title: "Loading",
        subtitle: "Bootstrap task is resolving the current user.",
        variant: "Loading"
    )
}
