import SwiftUI




/// Settings section embedding RishiAudio's `VoiceAndSpeedPicker` for SET-01
/// audio controls. Receives the initial settings + store + user id from the
/// parent screen; the picker persists changes back through the store and
/// notifies the parent via `onChange`.
public struct AudioSection: View {

    public let userId: UserID
    public let initialSettings: TTSSettings
    public let store: any TTSSettingsStore
    public let onChange: (TTSSettings) -> Void

    public init(
        userId: UserID,
        initialSettings: TTSSettings,
        store: any TTSSettingsStore,
        onChange: @escaping (TTSSettings) -> Void
    ) {
        self.userId = userId
        self.initialSettings = initialSettings
        self.store = store
        self.onChange = onChange
    }

    public var body: some View {
        Section {
            VoiceAndSpeedPicker(
                initial: initialSettings,
                userId: userId,
                store: store,
                onDismiss: onChange
            )
        } header: {
            Text("Audio")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview("Audio") {
    Form {
        AudioSection(
            userId: UUID(),
            initialSettings: .default,
            store: InMemoryTTSSettingsStore(),
            onChange: { _ in }
        )
    }
}
