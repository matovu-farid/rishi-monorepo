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
                WelcomeScreen(onGetStarted: beginWelcomeTransition, logo: "rishi")

            case .voiceLanguagePrimer:
                VoiceLanguagePrimer(
                    selection: $voiceLanguage,
                    onBack: coordinator.back,
                    onContinue: continueLanguage,
                    onSkip: skipLanguage
                )

            case .firstReaderHint:
                FirstReaderHint(onBack: coordinator.back, onGotIt: completeHint)

            case .completed:
                Color.clear.onAppear { onCompleted() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let step = coordinator.currentStage.introStep {
                OnboardingProgressView(step: step)
            }
        }
        .disabled(coordinator.isTransitioning)
    }

    private func beginWelcomeTransition() {
        guard coordinator.beginTransition() else { return }
        Task {
            defer { coordinator.endTransition() }
            await coordinator.advance()
        }
    }

    private func continueLanguage() {
        guard coordinator.beginTransition() else { return }
        Task {
            defer { coordinator.endTransition() }
            await coordinator.advance()
        }
    }

    private func skipLanguage() {
        guard coordinator.beginTransition() else { return }
        Task {
            defer { coordinator.endTransition() }
            await coordinator.skipCurrentStage()
        }
    }

    private func completeHint() {
        guard coordinator.beginTransition() else { return }
        Task {
            defer { coordinator.endTransition() }
            await coordinator.advance()
            onCompleted()
        }
    }
}
