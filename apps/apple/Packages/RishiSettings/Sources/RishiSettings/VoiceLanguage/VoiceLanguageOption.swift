import Foundation

/// User-facing language options for voice sessions.
///
/// The stored value is the ISO-639-1 language code used by the voice
/// pipeline. English is the first-run default.
public enum VoiceLanguageOption: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case hindi = "hi"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .hindi: return "Hindi"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .arabic: return "Arabic"
        }
    }

    public static let defaultCode: String = VoiceLanguageOption.english.rawValue

    public static func label(for code: String) -> String {
        Self(rawValue: code)?.label ?? code
    }
}
