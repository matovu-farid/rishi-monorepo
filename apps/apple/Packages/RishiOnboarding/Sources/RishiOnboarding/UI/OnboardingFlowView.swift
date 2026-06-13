import SwiftUI
import RishiUIKit

/// Top-level View switching on `coordinator.currentStage`. 11-06 presents
/// this as a `.fullScreenCover` when `state.hasCompletedOnboarding == false`
/// on launch.
///
/// The signIn stage delegates to `onSignIn` — the actual sign-in surface is
/// owned by the app layer (existing SIWA + Google buttons in RishiAuth). The
/// sample / import / mic / notifications stages are wired to closures that
/// 11-06 connects to SampleBookInstaller / ImportCoordinator / AVAudioApplication
/// / UNUserNotificationCenter respectively.
public struct OnboardingFlowView: View {

    @Bindable private var coordinator: OnboardingCoordinator

    public let onSignIn: () async -> Void
    public let onUseSample: () async -> Void
    public let onImport: () -> Void
    public let onRequestMic: () async -> Void
    public let onRequestNotifications: () async -> Void
    public let onCompleted: () -> Void

    public init(
        coordinator: OnboardingCoordinator,
        onSignIn: @escaping () async -> Void,
        onUseSample: @escaping () async -> Void,
        onImport: @escaping () -> Void,
        onRequestMic: @escaping () async -> Void,
        onRequestNotifications: @escaping () async -> Void,
        onCompleted: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.onSignIn = onSignIn
        self.onUseSample = onUseSample
        self.onImport = onImport
        self.onRequestMic = onRequestMic
        self.onRequestNotifications = onRequestNotifications
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
                })

            case .signIn:
                // The actual sign-in surface is owned by the app layer
                // (RishiAuth's existing SIWA + Google buttons). 11-06 wires
                // `onSignIn` to present that surface; on success the closure
                // returns and we advance.
                VStack(spacing: RishiSpacing.l) {
                    Spacer()
                    ProgressView()
                    Text("Continuing to sign in…")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RishiColor.surfaceElevated.ignoresSafeArea())
                .task {
                    await onSignIn()
                    await coordinator.advance()
                }

            case .sampleOrImport:
                SampleOrImportScreen(
                    onUseSample: {
                        // KEEP: onUseSample is supplied by the host
                        // (SampleBookInstaller actor); coordinator.advance
                        // updates @MainActor coordinator state.
                        Task {
                            await onUseSample()
                            await coordinator.advance()
                        }
                    },
                    onImport: {
                        onImport()
                        // KEEP: coordinator advance only.
                        Task { await coordinator.advance() }
                    },
                    onSkip: {
                        // KEEP: coordinator advance only.
                        Task { await coordinator.advance() }
                    }
                )

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

            case .notificationsPrimer:
                NotificationsPermissionPrimer(
                    onAllow: {
                        // KEEP: onRequestNotifications awaits UNUserNotificationCenter
                        // permission (system sheet) and updates coordinator state.
                        Task {
                            await onRequestNotifications()
                            await coordinator.advance()
                        }
                    },
                    onSkip: {
                        // KEEP: coordinator skip-stage only.
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
