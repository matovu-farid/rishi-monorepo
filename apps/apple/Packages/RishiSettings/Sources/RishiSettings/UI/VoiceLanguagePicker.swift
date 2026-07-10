import SwiftUI
import RishiUIKit

/// Reusable picker for the user-selected voice language.
public struct VoiceLanguagePicker: View {

    @Binding private var selection: VoiceLanguageOption

    public init(selection: Binding<VoiceLanguageOption>) {
        self._selection = selection
    }

    public var body: some View {
        Picker("Language", selection: $selection) {
            ForEach(VoiceLanguageOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings-voice-language")
    }
}
