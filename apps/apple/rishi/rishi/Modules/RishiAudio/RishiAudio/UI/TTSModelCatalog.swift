import Foundation

/// OpenAI TTS model options exposed to the user.
public enum TTSModelCatalog {
    public static let all: [String] = [
        "gpt-4o-mini-tts",
    ]

    public static let defaultModel = "gpt-4o-mini-tts"

    public static func displayName(for id: String) -> String {
        switch id {
        case "gpt-4o-mini-tts":
            return "GPT-4o mini TTS"
        default:
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
