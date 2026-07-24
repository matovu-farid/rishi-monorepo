











import SwiftUI
import RishiOnboarding
import RishiCore
import RishiSettings
#if canImport(AVFoundation)
import AVFoundation
#endif








struct OnboardingHost: View {

    let services: BootstrappedServices
    let onCompleted: () -> Void

    var body: some View {
#if DEBUG
        Button("Erase Keychain") {
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            Keychain.delete(.userId)
            Task {
                try? await KeychainSessionStore().delete()
            }
        }
#endif
        OnboardingFlowView(
            coordinator: services.onboardingCoordinator,
            onRequestMic: {
                #if canImport(AVFoundation)
                if #available(iOS 17.0, macCatalyst 17.0, *) {
                    _ = await AVAudioApplication.requestRecordPermission()
                }
                #endif
            },
            voiceLanguage: Binding(
                get: { services.readerDefaults.voiceLanguage.rawValue },
                set: { services.readerDefaults.voiceLanguage = VoiceLanguageOption(rawValue: $0) ?? .english }
            ),
            onCompleted: onCompleted
        )
    }
}

#Preview("First step") {
    PreviewPlaceholder(
        title: "Welcome to Rishi",
        subtitle: "Choose how you want to start.",
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
