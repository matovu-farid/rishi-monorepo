




import SwiftUI

struct OnboardingHost: View {

    let coordinator: OnboardingCoordinator
    let readerDefaults: AppReaderDefaults
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
            coordinator: coordinator,
            voiceLanguage: Binding(
                get: { readerDefaults.voiceLanguage.rawValue },
                set: { readerDefaults.voiceLanguage = VoiceLanguageOption(rawValue: $0) ?? .english }
            ),
            onCompleted: onCompleted
        )
    }
}

#Preview("First step") {
    OnboardingHost(
        coordinator: OnboardingCoordinator(state: InMemoryOnboardingState()),
        readerDefaults: AppReaderDefaults(defaults: UserDefaults()),
        onCompleted: {}
    )
}

#Preview("Last step") {
    let coordinator = OnboardingCoordinator(state: InMemoryOnboardingState())
    coordinator.setStageForTest(.firstReaderHint)
    return OnboardingHost(
        coordinator: coordinator,
        readerDefaults: AppReaderDefaults(defaults: UserDefaults()),
        onCompleted: {}
    )
}
