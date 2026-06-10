import Foundation

/// Single request to the Worker `/api/audio/speech` endpoint. `passageId` is
/// optional and carries TTS-06 link-back so the player can map an audio chunk
/// back to the reader passage it was synthesised from.
public struct TTSStreamRequest: Sendable, Equatable {
    public let text: String
    public let voice: String
    public let speed: Double
    public let passageId: String?

    public init(text: String, voice: String, speed: Double, passageId: String? = nil) {
        self.text = text
        self.voice = voice
        self.speed = speed
        self.passageId = passageId
    }
}
