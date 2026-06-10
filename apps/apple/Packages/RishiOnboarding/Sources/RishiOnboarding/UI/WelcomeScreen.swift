import SwiftUI
import RishiUIKit

/// First-run welcome screen. ONB-01.
public struct WelcomeScreen: View {
    public let onGetStarted: () -> Void

    public init(onGetStarted: @escaping () -> Void) {
        self.onGetStarted = onGetStarted
    }

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Spacer(minLength: 0)

            Image(systemName: "book.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(RishiColor.accent)
                .accessibilityHidden(true)

            Text("Welcome to Rishi")
                .font(RishiTypography.titleL)
                .foregroundStyle(RishiColor.textPrimary)

            VStack(alignment: .leading, spacing: RishiSpacing.m) {
                bullet("Read EPUB + PDF books on every device")
                bullet("Highlight passages and add notes")
                bullet("Ask the AI about what you're reading")
            }
            .padding(.horizontal, RishiSpacing.l)

            Spacer(minLength: 0)

            Button(action: onGetStarted) {
                Text("Get started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
            .accessibilityIdentifier("onboarding-welcome-start")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.surfaceElevated.ignoresSafeArea())
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
    WelcomeScreen(onGetStarted: {})
}
