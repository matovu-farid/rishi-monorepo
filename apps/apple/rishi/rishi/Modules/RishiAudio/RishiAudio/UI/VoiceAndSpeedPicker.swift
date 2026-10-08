import SwiftUI



/// Voice + speed picker bound to a `TTSSettingsStore`. Loads initial state
/// from the store on `task`, saves on Done. All visuals use `RishiUIKit`
/// tokens exclusively.
@MainActor
public struct VoiceAndSpeedPicker: View {

    @State private var presentationSnapshot: VoiceAndSpeedPickerState
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
        self._presentationSnapshot = State(
            initialValue: VoiceAndSpeedPickerState(catalog: catalog, initial: initial)
        )
        self.userId = userId
        self.store = store
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.l) {
            Text("Voice")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)

            Picker("Voice", selection: voiceBinding) {
                ForEach(presentationSnapshot.catalog.voiceChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("tts-voice-picker")
            .accessibilityValue(
                presentationSnapshot.catalog.voiceChoices.first {
                    $0.id == presentationSnapshot.voice
                }?.name ?? presentationSnapshot.voice
            )

            Text(speedLabel)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)

            Slider(value: speedBinding, in: TTSSettings.speedRange, step: 0.25)
                .accessibilityIdentifier("tts-speed-slider")
                .accessibilityLabel("Reading speed")

            Spacer()

            Button {
                let settings = presentationSnapshot.settings
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
        String(format: "Speed: %.2fx", presentationSnapshot.settings.speed)
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: { presentationSnapshot.voice },
            set: { presentationSnapshot.updateVoice($0) }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { presentationSnapshot.speed },
            set: { presentationSnapshot.updateSpeed($0) }
        )
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
