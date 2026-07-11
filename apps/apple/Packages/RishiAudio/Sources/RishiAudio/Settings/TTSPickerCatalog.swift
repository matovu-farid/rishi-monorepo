import Foundation
import Observation

/// Picker options for read-aloud settings.
///
/// The worker supplies the active provider's choices at startup so the UI can
/// adapt when the backend switches between OpenAI and ElevenLabs.
public struct TTSPickerCatalog: Sendable, Hashable {

    public let voiceChoices: [TTSVoiceChoice]
    public let modelChoices: [TTSVoiceChoice]
    public let defaultVoiceID: String
    public let defaultModelID: String

    public init(
        voiceChoices: [TTSVoiceChoice],
        modelChoices: [TTSVoiceChoice],
        defaultVoiceID: String,
        defaultModelID: String
    ) {
        self.voiceChoices = voiceChoices
        self.modelChoices = modelChoices
        self.defaultVoiceID = defaultVoiceID
        self.defaultModelID = defaultModelID
    }

    public static let fallback = TTSPickerCatalog(
        voiceChoices: VoiceCatalog.all.map {
            TTSVoiceChoice(id: $0, name: VoiceCatalog.displayName(for: $0))
        },
        modelChoices: TTSModelCatalog.all.map {
            TTSVoiceChoice(id: $0, name: TTSModelCatalog.displayName(for: $0))
        },
        defaultVoiceID: VoiceCatalog.all.first ?? "marin",
        defaultModelID: TTSModelCatalog.defaultModel
    )

    public func normalized(_ settings: TTSSettings) -> TTSSettings {
        let voice = contains(settings.voice, in: voiceChoices)
            ? settings.voice
            : defaultVoiceID
        let model = contains(settings.model, in: modelChoices)
            ? settings.model
            : defaultModelID
        return TTSSettings(voice: voice, model: model, speed: settings.speed)
    }

    private func contains(_ id: String, in choices: [TTSVoiceChoice]) -> Bool {
        choices.contains { $0.id == id }
    }
}

@MainActor
@Observable
public final class TTSPickerCatalogStore {
    public static let shared = TTSPickerCatalogStore()

    public var catalog: TTSPickerCatalog = .fallback

    private init() {}
}
