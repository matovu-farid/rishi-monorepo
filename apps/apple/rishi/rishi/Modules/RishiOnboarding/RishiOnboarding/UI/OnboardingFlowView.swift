import SwiftUI


/// Top-level View switching on `coordinator.currentStage`. 11-06 presents
/// this as a `.fullScreenCover` when `state.hasCompletedOnboarding == false`
/// on launch.
///
/// Voice permission is requested only by the consented voice flow. The
/// language primer remains part of onboarding, while book selection is
/// presented from the authenticated library instead of this intro wizard.
public struct OnboardingFlowView: View {

    @Bindable private var coordinator: OnboardingCoordinator

    @Binding public var voiceLanguage: String
    public let onCompleted: () -> Void

    public init(
        coordinator: OnboardingCoordinator,
        voiceLanguage: Binding<String>,
        onCompleted: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self._voiceLanguage = voiceLanguage
        self.onCompleted = onCompleted
    }

    public var body: some View {
        Group {
            switch coordinator.currentStage {
            case .welcome:
                WelcomeScreen(onGetStarted: {
                    // KEEP: coordinator is an @Observable @MainActor; advance
                    // mutates currentStage which SwiftUI observes.
                    Task { await coordinator.advance() }
                }, logo: "rishi")

            case .voiceLanguagePrimer:
                VoiceLanguagePrimer(
                    selection: $voiceLanguage,
                    onContinue: {
                        Task { await coordinator.advance() }
                    },
                    onSkip: {
                        Task { await coordinator.skipCurrentStage() }
                    }
                )

            case .firstReaderHint:
                FirstReaderHint(onGotIt: {
                    // KEEP: coordinator advance + onCompleted callback (both UI).
                    Task {
                        await coordinator.advance()
                        onCompleted()
                    }
                })

            case .completed:
                Color.clear.onAppear { onCompleted() }
            }
        }
    }
}
