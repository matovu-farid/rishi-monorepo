import Foundation

/// Per-user TTS preferences (TTS-07).
///
/// The app keeps stable voice and model presets and lets the worker map those
/// presets to the active provider's identifiers. Speed is clamped to
/// [0.5, 2.0] at the model boundary so callers cannot persist out-of-range values.
public struct TTSSettings: Sendable, Codable, Equatable {

    public static let speedRange: ClosedRange<Double> = 0.5...2.0
    public static let `default` = TTSSettings(
        voice: "marin",
        model: TTSModelCatalog.defaultModel,
        speed: 1.0
    )

    public let voice: String
    public let model: String
    public let speed: Double

    public init(
        voice: String,
        model: String = TTSModelCatalog.defaultModel,
        speed: Double
    ) {
        self.voice = voice
        self.model = model
        let clamped = Swift.min(Swift.max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        self.speed = clamped
    }

    private enum CodingKeys: String, CodingKey {
        case voice
        case model
        case speed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let voice = try container.decode(String.self, forKey: .voice)
        let model = try container.decodeIfPresent(String.self, forKey: .model) ?? TTSModelCatalog.defaultModel
        let speed = try container.decode(Double.self, forKey: .speed)
        self.init(voice: voice, model: model, speed: speed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voice, forKey: .voice)
        try container.encode(model, forKey: .model)
        try container.encode(speed, forKey: .speed)
    }
}
