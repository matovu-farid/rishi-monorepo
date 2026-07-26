import Foundation

/// Voice presets the app exposes for read-aloud.
///
/// The worker maps these stable preset names onto provider-specific voice IDs,
/// so the picker can stay stable while the backend switches from OpenAI to
/// ElevenLabs.
public enum VoiceCatalog {
    public static let all: [String] = [
        "alloy",
        "ash",
        "ballad",
        "coral",
        "echo",
        "fable",
        "nova",
        "onyx",
        "sage",
        "shimmer",
        "verse",
        "marin",
        "cedar",
    ]

    private static let elevenLabsVoiceIDs: [String: String] = [
        "alloy": "JBFqnCBsd6RMkjVDRZzb",
        "ash": "29vD33N1CtxCmqQRPOHJ",
        "ballad": "EXAVITQu4vr4xnSDxMaL",
        "coral": "ErXwobaYiN019PkySvjV",
        "echo": "MF3mGyEYCl7XYWbV9V6O",
        "fable": "TxGEqnHWrfWFTfGW9XjX",
        "nova": "VR6AewLTigWG4xSOukaG",
        "onyx": "pNInz6obpgDQGcFmaJgB",
        "sage": "yoZ06aMxZJJ28mfd3POQ",
        "shimmer": "pMsXgVXv3BLzUgSXRplE",
        "verse": "IKne3meq5aSn9XLyUdCD",
        "marin": "21m00Tcm4TlvDq8ikWAM",
        "cedar": "N2lVS1w4EtoT3dr4eOWO",
    ]

    /// Capitalised label for the picker UI (e.g. "alloy" → "Alloy").
    public static func displayName(for id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// Maps the stable reader preset to the ElevenLabs voice ID used by the
    /// worker. Returns nil for unknown custom presets.
    public static func providerVoiceID(for preset: String) -> String? {
        elevenLabsVoiceIDs[preset]
    }
}
