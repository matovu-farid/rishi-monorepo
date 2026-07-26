import SwiftUI
import RishiUIKit

/// Onboarding screen that lets the user confirm or change the default voice
/// language before they enter the app.
public struct VoiceLanguagePrimer: View {

    @Binding private var selection: String
    public let onContinue: () -> Void
    public let onSkip: () -> Void

    public init(
        selection: Binding<String>,
        onContinue: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self._selection = selection
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .belowContent) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text("Choose your language")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("English is the default. Pick a different language now if you want the assistant to reply and transcribe in that language.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
                    .onboardingContentWidth()

                Picker("Language", selection: $selection) {
                    ForEach(Self.options, id: \.code) { option in
                        Text(option.label).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            VStack(spacing: RishiSpacing.m) {
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                        .onboardingCTAWidth()
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("onboarding-language-continue")

                Button("Not now", action: onSkip)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("onboarding-language-skip")
            }
            .padding(.horizontal, RishiSpacing.l)
        }
    }

    private static let options: [LanguageOption] = [
        .init(code: "en", label: "English"),
        .init(code: "es", label: "Spanish"),
        .init(code: "fr", label: "French"),
        .init(code: "de", label: "German"),
        .init(code: "it", label: "Italian"),
        .init(code: "pt", label: "Portuguese"),
        .init(code: "hi", label: "Hindi"),
        .init(code: "ja", label: "Japanese"),
        .init(code: "ko", label: "Korean"),
        .init(code: "zh", label: "Chinese"),
        .init(code: "ar", label: "Arabic"),
    ]

    private struct LanguageOption: Sendable, Hashable {
        let code: String
        let label: String
    }
}

#Preview {
    VoiceLanguagePrimer(
        selection: .constant("en"),
        onContinue: {},
        onSkip: {}
    )
}
