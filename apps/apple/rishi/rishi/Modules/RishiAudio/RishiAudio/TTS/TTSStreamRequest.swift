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
    public let sessionToken: UUID
    public let utteranceToken: UUID
    public let requestToken: UUID

    public init(
        text: String,
        voice: String,
        model: String = TTSModelCatalog.defaultModel,
        speed: Double,
        passageId: String? = nil,
        sessionToken: UUID = UUID(),
        utteranceToken: UUID = UUID(),
        requestToken: UUID = UUID()
    ) {
        self.text = text
        self.voice = voice
        self.model = model
        self.speed = speed
        self.passageId = passageId
        self.sessionToken = sessionToken
        self.utteranceToken = utteranceToken
        self.requestToken = requestToken
    }

    public var tokenSnapshot: TTSPlaybackTokenSnapshot {
        TTSPlaybackTokenSnapshot(
            sessionToken: sessionToken,
            utteranceToken: utteranceToken,
            requestToken: requestToken
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.voice == rhs.voice
            && lhs.model == rhs.model
            && lhs.speed == rhs.speed
            && lhs.passageId == rhs.passageId
    }
}
