import SwiftUI


extension OnboardingCoordinator.Stage {
    var introStep: Int? {
        switch self {
        case .welcome: 1
        case .voiceLanguagePrimer: 2
        case .firstReaderHint: 3
        case .completed: nil
        }
    }
}

struct OnboardingProgressView: View {
    let step: Int

    var body: some View {
        Text("Step \(step) of 3")
            .font(RishiTypography.caption)
            .foregroundStyle(RishiColor.textSecondary)
            .padding(.vertical, RishiSpacing.s)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("onboarding-progress")
    }
}
