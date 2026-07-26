import SwiftUI


/// Settings section for the app-wide voice language preference.
public struct VoiceLanguageSection: View {

    @Binding private var selection: VoiceLanguageOption

    public init(selection: Binding<VoiceLanguageOption>) {
        self._selection = selection
    }

    public var body: some View {
        Section {
            VoiceLanguagePicker(selection: $selection)
        } header: {
            Text("Voice Language")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        } footer: {
            Text("Used for voice chat and reconnects. You can change it anytime.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        }
    }
}

#Preview("Voice Language") {
    Form {
        VoiceLanguageSection(selection: .constant(.english))
    }
}
