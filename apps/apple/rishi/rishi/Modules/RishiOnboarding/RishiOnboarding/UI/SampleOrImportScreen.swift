import SwiftUI


/// First-library-open prompt letting the user pick a sample book or import
/// their own. The app presents this after authentication, outside the intro
/// onboarding wizard.
public struct SampleOrImportScreen: View {
    public let onUseSample: () -> Void
    public let onImport: () -> Void
    public let onSkip: () -> Void

    public init(
        onUseSample: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.onUseSample = onUseSample
        self.onImport = onImport
        self.onSkip = onSkip
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text("Bring a book to Rishi")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)

                Text("Import something you’re reading and we’ll show you how to listen and talk about it. You can also try a sample book.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            VStack(spacing: RishiSpacing.m) {
                Button(action: onImport) {
                    Text("Import your book")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                        .onboardingCTAWidth()
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("onboarding-sample-import")

                Button(action: onUseSample) {
                    Text("Use a sample book")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                        .onboardingCTAWidth()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-sample-use")

                Button("Skip for now", action: onSkip)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("onboarding-sample-skip")
            }
            .padding(.horizontal, RishiSpacing.l)
        }
    }
}

#Preview {
    SampleOrImportScreen(onUseSample: {}, onImport: {}, onSkip: {})
}
