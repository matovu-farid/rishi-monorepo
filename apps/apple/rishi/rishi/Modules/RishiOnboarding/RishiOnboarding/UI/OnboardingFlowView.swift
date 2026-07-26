import SwiftUI


/// Top-level View switching on `coordinator.currentStage`. 11-06 presents
/// this as a `.fullScreenCover` when `state.hasCompletedOnboarding == false`
/// on launch.
///
/// The mic / language primer stages are wired to app-owned closures for
/// AVAudioApplication and AppReaderDefaults respectively. Book selection is
/// presented from the authenticated library instead of this intro wizard.
public struct OnboardingFlowView: View {

    @Bindable private var coordinator: OnboardingCoordinator

    public let onRequestMic: () async -> Void
    @Binding public var voiceLanguage: String
    public let onCompleted: () -> Void

    public init(
        coordinator: OnboardingCoordinator,
        onRequestMic: @escaping () async -> Void,
        voiceLanguage: Binding<String>,
        onCompleted: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.onRequestMic = onRequestMic
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

            case .micPrimer:
                MicPermissionPrimer(
                    onAllow: {
                        // KEEP: onRequestMic awaits AVAudioApplication permission
                        // (system sheet) and coordinator.advance updates @MainActor
                        // observable state.
                        Task {
                            await onRequestMic()
                            await coordinator.advance()
                        }
                    },
                    onSkip: {
                        // KEEP: coordinator skip-stage only.
                        Task { await coordinator.skipCurrentStage() }
                    }
                )

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
