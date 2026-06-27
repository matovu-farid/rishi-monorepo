











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








struct OnboardingHost: View {

    let services: BootstrappedServices
    let onCompleted: () -> Void

    var body: some View {
        OnboardingFlowView(
            coordinator: services.onboardingCoordinator,
            onSignIn: { [services] in
                
                
                
//                _ = await services.entitlementService.refresh()
            },
            onUseSample: { [services] in
                guard let userId = await services.authService.currentUser?.id else { return }
                _ = await services.sampleBookInstaller.installIfNeeded(ownerId: userId)
            },
            onImport: {
                
                
                
                
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
