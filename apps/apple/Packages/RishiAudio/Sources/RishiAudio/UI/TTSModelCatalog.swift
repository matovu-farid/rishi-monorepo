import Foundation

/// ElevenLabs TTS model options exposed to the user.
public enum TTSModelCatalog {
    public static let all: [String] = [
        "eleven_v3",
        "eleven_flash_v2_5",
        "eleven_flash_v2",
        "eleven_multilingual_v2",
    ]

    public static let defaultModel = "eleven_v3"

    public static func displayName(for id: String) -> String {
        switch id {
        case "eleven_v3":
            return "Eleven v3"
        case "eleven_flash_v2_5":
            return "Flash v2.5"
        case "eleven_flash_v2":
            return "Flash v2"
        case "eleven_multilingual_v2":
            return "Multilingual v2"
        default:
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
