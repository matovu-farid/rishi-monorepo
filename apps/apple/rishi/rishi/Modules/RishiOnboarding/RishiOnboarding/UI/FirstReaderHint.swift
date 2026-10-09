import SwiftUI


/// ONB-01 final visible step. Overlay-style coachmark guiding the user to
/// open a book or import something they are reading.
struct FirstReaderHint: View {
    public let onBack: () -> Void
    public let onGotIt: () -> Void

    public init(onBack: @escaping () -> Void, onGotIt: @escaping () -> Void) {
        self.onBack = onBack
        self.onGotIt = onGotIt
    }

    public var body: some View {
        OnboardingScrollContainer {
            RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
                VStack(spacing: RishiSpacing.l) {
                    Image(systemName: "hand.tap.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .foregroundStyle(RishiColor.accent)
                        .accessibilityHidden(true)

                    Text("Make yourself at home")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    Text("After signing in, open a book from your library or import something you’re reading.")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, RishiSpacing.l)
                }
            } actions: {
                VStack(spacing: RishiSpacing.m) {
                    Button(action: onGotIt) {
                        Text("Got it")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, RishiSpacing.m)
                            .onboardingCTAWidth()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RishiColor.accent)
                    .accessibilityIdentifier("onboarding-hint-gotit")

                    Button(action: onBack) {
                        Text("Back")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("onboarding-hint-back")
                }
                .padding(.horizontal, RishiSpacing.l)
                .padding(.bottom, RishiSpacing.l)
            }
        }
    }
}

#Preview {
    FirstReaderHint(onBack: {}, onGotIt: {})
}
