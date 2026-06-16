import SwiftUI
import RishiUIKit

/// ONB-01 final visible step. Overlay-style coachmark telling the user to
/// tap any book cover to start reading.
struct FirstReaderHint: View {
    public let onGotIt: () -> Void

    public init(onGotIt: @escaping () -> Void) {
        self.onGotIt = onGotIt
    }

    public var body: some View {
        OnboardingScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "hand.tap.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text("Tap a book to open it")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)

                Text("Your library is ready. Tap any book cover to start reading, or use the toolbar to import more.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            Button(action: onGotIt) {
                Text("Got it")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
            .accessibilityIdentifier("onboarding-hint-gotit")
        }
    }
}

#Preview {
    FirstReaderHint(onGotIt: {})
}
