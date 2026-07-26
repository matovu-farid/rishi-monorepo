import Foundation

/// Single request to the worker speech endpoint. `passageId` is optional and
/// carries TTS-06 link-back so the player can map an audio chunk back to the
/// reader passage it was synthesised from.
public struct TTSStreamRequest: Sendable, Equatable {
    public let text: String
    public let voice: String
    public let model: String
    public let speed: Double
    public let passageId: String?

    public init(
        text: String,
        voice: String,
        model: String = TTSModelCatalog.defaultModel,
        speed: Double,
        passageId: String? = nil
    ) {
        self.text = text
        self.voice = voice
        self.model = model
        self.speed = speed
        self.passageId = passageId
    }
}
