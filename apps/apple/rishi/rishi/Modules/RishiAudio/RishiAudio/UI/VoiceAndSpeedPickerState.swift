import Foundation

struct VoiceAndSpeedPickerState {
    let catalog: TTSPickerCatalog
    private(set) var voice: String
    private(set) var model: String
    private(set) var speed: Double

    var settings: TTSSettings {
        TTSSettings(voice: voice, model: model, speed: speed)
    }

    init(catalog: TTSPickerCatalog, initial: TTSSettings) {
        self.catalog = catalog
        let normalized = catalog.normalized(initial)
        self.voice = normalized.voice
        self.model = normalized.model
        self.speed = normalized.speed
    }

    mutating func updateVoice(_ voice: String) {
        self.voice = voice
    }

    mutating func updateSpeed(_ speed: Double) {
        self.speed = speed
    }
}
