import Foundation

/// Voice IDs the Worker `/api/audio/speech` endpoint exposes (OpenAI-backed
/// as of 2026-06). Kept inside `RishiAudio` so the picker UI is fully
/// self-contained — change the list here when the Worker adds custom
/// voices.
public enum VoiceCatalog {
    public static let all: [String] = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

    /// Capitalised label for the picker UI (e.g. "alloy" → "Alloy").
    public static func displayName(for id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }
}
