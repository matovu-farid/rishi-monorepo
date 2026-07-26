import SwiftUI



/// Voice + speed picker bound to a `TTSSettingsStore`. Loads initial state
/// from the store on `task`, saves on Done. All visuals use `RishiUIKit`
/// tokens exclusively.
@MainActor
public struct VoiceAndSpeedPicker: View {

    @State private var voice: String
    @State private var speed: Double
    private let model: String
    private let voiceChoices: [TTSVoiceChoice]
    let userId: UserID
    let store: any TTSSettingsStore
    let onDismiss: (TTSSettings) -> Void

    public init(
        initial: TTSSettings,
        userId: UserID,
        store: any TTSSettingsStore,
        catalog: TTSPickerCatalog = TTSPickerCatalogStore.shared.catalog,
        onDismiss: @escaping (TTSSettings) -> Void
    ) {
        let normalized = catalog.normalized(initial)
        self._voice = State(initialValue: normalized.voice)
        self._speed = State(initialValue: initial.speed)
        self.model = initial.model
        self.voiceChoices = catalog.voiceChoices
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
                ForEach(voiceChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("tts-voice-picker")

            Text(speedLabel)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)

            Slider(value: $speed, in: TTSSettings.speedRange, step: 0.25)
                .accessibilityIdentifier("tts-speed-slider")
                .accessibilityLabel("Reading speed")

            Spacer()

            Button {
                let settings = TTSSettings(voice: voice, model: model, speed: speed)
                let store = store
                let userId = userId
                // KEEP: store.save is an actor method; the `await` already hops
                // off MainActor. Phase 20 revert of gratuitous `Task.detached`
                // — see SWIFT-CONCURRENCY-RULES.md Pattern A.
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
        initial: TTSSettings(voice: "nova", model: "eleven_flash_v2_5", speed: 1.5),
        userId: UserID(),
        store: InMemoryTTSSettingsStore(),
        onDismiss: { _ in }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RishiColor.surface)
}
