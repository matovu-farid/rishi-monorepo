import SwiftUI
import RishiUIKit
import RishiCore

/// Voice + speed picker bound to a `TTSSettingsStore`. Loads initial state
/// from the store on `task`, saves on Done. All visuals use `RishiUIKit`
/// tokens exclusively.
@MainActor
public struct VoiceAndSpeedPicker: View {

    @State private var voice: String
    @State private var speed: Double
    let userId: UserID
    let store: any TTSSettingsStore
    let onDismiss: (TTSSettings) -> Void

    public init(
        initial: TTSSettings,
        userId: UserID,
        store: any TTSSettingsStore,
        onDismiss: @escaping (TTSSettings) -> Void
    ) {
        self._voice = State(initialValue: initial.voice)
        self._speed = State(initialValue: initial.speed)
        self.userId = userId
        self.store = store
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.l) {
            Text("Voice")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)

            Picker("Voice", selection: $voice) {
                ForEach(VoiceCatalog.all, id: \.self) { id in
                    Text(VoiceCatalog.displayName(for: id)).tag(id)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tts-voice-picker")

            Text(speedLabel)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)

            Slider(value: $speed, in: TTSSettings.speedRange, step: 0.25)
                .accessibilityIdentifier("tts-speed-slider")
                .accessibilityLabel("Reading speed")

            Spacer()

            Button {
                let settings = TTSSettings(voice: voice, speed: speed)
                let store = store
                let userId = userId
                Task { await store.save(settings, userId: userId) }
                onDismiss(settings)
            } label: {
                Text("Done")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.accent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.vertical, RishiSpacing.s)
            }
            .accessibilityIdentifier("tts-picker-done")
            .accessibilityLabel("Done")
        }
        .padding(RishiSpacing.l)
        .background(RishiColor.surfaceElevated)
    }

    private var speedLabel: String {
        String(format: "Speed: %.2fx", speed)
    }
}

#Preview("Default voice") {
    VoiceAndSpeedPicker(
        initial: .default,
        userId: UserID(),
        store: InMemoryTTSSettingsStore(),
        onDismiss: { _ in }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RishiColor.surface)
}

#Preview("Alt voice") {
    VoiceAndSpeedPicker(
        initial: TTSSettings(voice: "nova", speed: 1.5),
        userId: UserID(),
        store: InMemoryTTSSettingsStore(),
        onDismiss: { _ in }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RishiColor.surface)
}
