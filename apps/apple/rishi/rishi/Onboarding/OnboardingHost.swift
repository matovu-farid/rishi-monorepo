//
//  OnboardingHost.swift
//  rishi
//
//  Phase 11 Plan 11-06 — hosts `OnboardingFlowView` and supplies the
//  closures wiring the flow's stages to `RishiAuthService`, sample-book
//  install, mic + notifications permission requests.
//
//  This view is presented as a `.fullScreenCover` by `RootView` whenever
//  `OnboardingState.hasCompletedOnboarding == false` on launch.
//

import SwiftUI
import RishiOnboarding
import RishiAuth
import RishiBilling
import RishiCore
import RishiLibrary
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Hosts `OnboardingFlowView` and forwards its stage closures into the
/// existing app services owned by `AppDependencies`.
///
/// The signIn stage's `onSignIn` closure is fire-and-forget: the actual SIWA
/// surface comes up via the signed-out path in `RootView`. Once
/// `RishiAuthService.currentUser` resolves, we refresh the entitlement and
/// advance.
struct OnboardingHost: View {

    let dependencies: AppDependencies
    let onCompleted: () -> Void

    var body: some View {
        OnboardingFlowView(
            coordinator: dependencies.onboardingCoordinator,
            onSignIn: { [dependencies] in
                // Refresh the entitlement cache once the user is signed in so
                // the Settings → Subscription section + paywall reflect
                // accurate state on first reach.
                _ = await dependencies.entitlementService.refresh()
            },
            onUseSample: { [dependencies] in
                guard let userId = await dependencies.authService.currentUser?.id else { return }
                _ = await dependencies.sampleBookInstaller.installIfNeeded(ownerId: userId)
            },
            onImport: {
                // The user can use the Library import button after onboarding;
                // launching a document picker from a fullScreenCover requires
                // a presenting controller this view does not have. We let the
                // flow advance — onUseSample / Skip are the supported paths.
            },
            onRequestMic: {
                #if canImport(AVFoundation)
                if #available(iOS 17.0, macCatalyst 17.0, *) {
                    _ = await AVAudioApplication.requestRecordPermission()
                }
                #endif
            },
            onRequestNotifications: {
                #if canImport(UserNotifications)
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                #endif
            },
            onCompleted: onCompleted
        )
    }
}

#Preview("First step") {
    PreviewPlaceholder(
        title: "Welcome to Rishi",
        subtitle: "Sign in, then choose how you want to start.",
        variant: "First step"
    )
}

#Preview("Last step") {
    PreviewPlaceholder(
        title: "First Reader Hint",
        subtitle: "Tap any book in the library to start reading.",
        variant: "Last step"
    )
}
