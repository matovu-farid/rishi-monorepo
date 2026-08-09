import Observation
import SwiftUI

enum ReaderOnboardingTourStep: Equatable {
    case readAloud
    case waitingForReadAloud
    case swipe
    case voiceChat
    case completed
}

@MainActor
@Observable
final class ReaderOnboardingTourCoordinator {
    private(set) var step: ReaderOnboardingTourStep = .readAloud

    func readAloudTapped() {
        guard step == .readAloud else { return }
        step = .waitingForReadAloud
    }

    func firstUtteranceFinished() {
        guard step == .waitingForReadAloud else { return }
        step = .swipe
    }

    func readAloudFailed() {
        guard step == .waitingForReadAloud else { return }
        step = .readAloud
    }

    func userNavigated() {
        guard step == .swipe else { return }
        step = .voiceChat
    }

    func voiceChatStarted() {
        guard step == .voiceChat else { return }
        step = .completed
    }

    func skip() {
        guard step != .completed else { return }
        step = .completed
    }
}

struct ReaderOnboardingTourOverlay: View {
    @Bindable private var coordinator: ReaderOnboardingTourCoordinator

    init(coordinator: ReaderOnboardingTourCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        if coordinator.step != .completed {
            VStack(spacing: 12) {
                Label(instruction.title, systemImage: instruction.symbol)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    // The reader owns horizontal page-turn gestures. The
                    // instructional surface must never become a gesture
                    // interception layer; only the bounded Skip button below
                    // participates in hit testing.
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("reader-onboarding-tour.instruction")

                Button("Skip tour", action: coordinator.skip)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reader-onboarding-tour.skip")
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader-onboarding-tour")
        }
    }

    private var instruction: (title: String, symbol: String) {
        switch coordinator.step {
        case .readAloud:
            ("Tap Read Aloud to hear this page.", "speaker.wave.2.fill")
        case .waitingForReadAloud:
            ("Listen to the first passage.", "speaker.wave.2.fill")
        case .swipe:
            ("Swipe to turn the page.", "hand.draw.fill")
        case .voiceChat:
            ("Tap Voice Chat to start talking.", "waveform.circle.fill")
        case .completed:
            ("", "")
        }
    }
}
