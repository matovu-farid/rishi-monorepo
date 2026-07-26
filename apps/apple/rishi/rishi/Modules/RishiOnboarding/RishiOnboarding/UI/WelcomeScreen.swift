import SwiftUI


/// First-run welcome screen. ONB-01.
struct WelcomeScreen: View {
    public let onGetStarted: () -> Void
    private var logo: String

    public init(onGetStarted: @escaping () -> Void, logo: String) {
        self.onGetStarted = onGetStarted
        self.logo = logo
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image( logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)
                    .clipShape(RoundedRectangle(cornerSize: CGSize(width: 16, height: 16)))

                Text("Welcome to Rishi")
                    .font(RishiTypography.titleL)
                    .foregroundStyle(RishiColor.textPrimary)

                VStack(alignment: .leading, spacing: RishiSpacing.m) {
                    bullet("Read EPUB + PDF books on every device")
                    bullet("Highlight passages and add notes")
                    bullet("Ask the AI about what you're reading")
                }
                .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            Button(action: onGetStarted) {
                Text("Get started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
                    .onboardingCTAWidth()
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
            .accessibilityIdentifier("onboarding-welcome-start")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: RishiSpacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(RishiColor.accent)
            Text(text)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview {
    WelcomeScreen(onGetStarted: {}, logo: "rishi")
}
