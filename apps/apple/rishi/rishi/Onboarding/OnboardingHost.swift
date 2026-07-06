











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
    @Environment(CurrentUserBox.self) private var currentUserBox

    var body: some View {
#if DEBUG
        Button("Erase Keychain") {
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            Keychain.delete(.userId)
        }
#endif
        OnboardingFlowView(
            coordinator: services.onboardingCoordinator,
            onSignIn: { 
                
                
                
            },
            onUseSample: { [services] in
                if case .signedIn(user: let user) = currentUserBox.state{
                    _ = await services.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                }
                
               
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
