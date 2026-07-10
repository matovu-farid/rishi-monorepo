import Foundation

/// A displayable TTS voice option used by the reader picker.
///
/// This is intentionally lightweight so app code can provide choices from
/// either the legacy OpenAI catalog or a native engine such as Readium's
/// Apple-backed TTS engine without adding a package dependency.
public struct TTSVoiceChoice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
