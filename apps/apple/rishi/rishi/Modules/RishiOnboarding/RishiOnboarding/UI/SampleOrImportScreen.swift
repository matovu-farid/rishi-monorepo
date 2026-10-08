import SwiftUI


/// First-library-open prompt letting the user pick a sample book or import
/// their own. The app presents this after authentication, outside the intro
/// onboarding wizard.
public struct SampleOrImportScreen: View {
    public let onUseSample: () -> Void
    public let onImport: () -> Void
    public let onSkip: () -> Void
    public let isSamplePreparing: Bool
    public let isSampleRetryable: Bool
    public let sampleFailureMessage: String?
    public let recoveryMessage: String?
    public let sampleUnavailable: Bool

    public init(
        onUseSample: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        isSamplePreparing: Bool = false,
        isSampleRetryable: Bool = false,
        sampleFailureMessage: String? = nil,
        recoveryMessage: String? = nil,
        sampleUnavailable: Bool = false
    ) {
        self.onUseSample = onUseSample
        self.onImport = onImport
        self.onSkip = onSkip
        self.isSamplePreparing = isSamplePreparing
        self.isSampleRetryable = isSampleRetryable
        self.sampleFailureMessage = sampleFailureMessage
        self.recoveryMessage = recoveryMessage
        self.sampleUnavailable = sampleUnavailable
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

                if let recoveryMessage {
                    Text(recoveryMessage)
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, RishiSpacing.l)
                        .accessibilityIdentifier("onboarding-sample-recovery")
                }

                if let sampleFailureMessage {
                    Text(sampleFailureMessage)
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, RishiSpacing.l)
                        .accessibilityIdentifier("onboarding-sample-error")
                }
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
                .disabled(isSamplePreparing)

                Button(action: onUseSample) {
                    Text(isSamplePreparing ? "Preparing your sample…" : isSampleRetryable ? "Try sample again" : "Use a sample book")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                        .onboardingCTAWidth()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-sample-use")
                .disabled(isSamplePreparing || sampleUnavailable)

                Button("Skip for now", action: onSkip)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("onboarding-sample-skip")
                    .disabled(isSamplePreparing)
            }
            .padding(.horizontal, RishiSpacing.l)
        }
        .interactiveDismissDisabled(isSamplePreparing)
    }
}

#Preview {
    SampleOrImportScreen(onUseSample: {}, onImport: {}, onSkip: {})
}
