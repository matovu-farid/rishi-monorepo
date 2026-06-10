import Foundation

/// Per-user TTS preferences (TTS-07). Voice IDs are worker-defined (e.g.
/// "alloy", "echo", "fable", "onyx", "nova", "shimmer" for the OpenAI-backed
/// /api/audio/speech endpoint); speed is clamped to [0.5, 2.0] at the model
/// boundary so callers cannot persist out-of-range values.
public struct TTSSettings: Sendable, Codable, Equatable {

    public static let speedRange: ClosedRange<Double> = 0.5...2.0
    public static let `default` = TTSSettings(voice: "alloy", speed: 1.0)

    public let voice: String
    public let speed: Double

    public init(voice: String, speed: Double) {
        self.voice = voice
        let clamped = Swift.min(Swift.max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        self.speed = clamped
    }
}
