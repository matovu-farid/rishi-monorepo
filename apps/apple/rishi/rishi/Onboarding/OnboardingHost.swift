




import SwiftUI

struct OnboardingHost: View {

    let coordinator: OnboardingCoordinator
    let readerDefaults: AppReaderDefaults
    let onCompleted: () -> Void
    private let eraseCredentialAccount: (() throws -> Void)?
    @State private var eraseError: String?

    init(coordinator: OnboardingCoordinator, readerDefaults: AppReaderDefaults,
         onCompleted: @escaping () -> Void) {
        self.coordinator = coordinator
        self.readerDefaults = readerDefaults
        self.onCompleted = onCompleted
        eraseCredentialAccount = nil
    }

    init(coordinator: OnboardingCoordinator, readerDefaults: AppReaderDefaults,
         eraseCredentialAccount: @escaping () throws -> Void, onCompleted: @escaping () -> Void) {
        self.coordinator = coordinator
        self.readerDefaults = readerDefaults
        self.eraseCredentialAccount = eraseCredentialAccount
        self.onCompleted = onCompleted
    }

    var body: some View {
#if DEBUG
        Button("Erase Keychain") {
            if let eraseCredentialAccount {
                do { try eraseCredentialAccount(); eraseError = nil }
                catch { eraseError = AuthenticationRecovery.forError(error)?.message ?? "Your account changed. Try again." }
                return
            }
            eraseError = "Account cleanup is not configured for this preview."
        }
        if let eraseError { Text(eraseError).foregroundStyle(.red) }
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
