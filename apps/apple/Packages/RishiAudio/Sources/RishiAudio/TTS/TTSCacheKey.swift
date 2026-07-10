import Foundation
import CryptoKit

/// Pure SHA-256 hex helper for the TTS audio cache.
///
/// MUST stay byte-for-byte symmetric with the worker-side `elevenLabsTtsCacheKey`
/// helper for the ElevenLabs speech route in `workers/worker/src/index.ts`. The
/// pinned canonical string
/// `"elevenlabs-tts|eleven_v3|JBFqnCBsd6RMkjVDRZzb|1.00|hello world"` is
/// asserted to produce the same hex by both this package's
/// TTSCacheKeyTests AND the worker's `audio-speech-elevenlabs.test.ts`. See
/// Phase 22 RESEARCH.md Pitfall 3 (speed canonicalization).
public enum TTSCacheKey {
    /// Computes the cache key for a TTS request.
    ///
    /// - Parameters:
    ///   - text: Synthesis text, raw (not normalised).
    ///   - voice: Any supported voice id for the current TTS model.
    ///   - model: ElevenLabs model id, part of the cache namespace.
    ///   - speed: Float speed, formatted with `%.2f` for canonicalization.
    /// - Returns: 64-character lowercase hex SHA-256 digest.
    public static func compute(
        text: String,
        voice: String,
        model: String = TTSModelCatalog.defaultModel,
        speed: Double
    ) -> String {
        let providerVoiceID = VoiceCatalog.providerVoiceID(for: voice) ?? voice
        let canonical = "elevenlabs-tts|\(model)|\(providerVoiceID)|\(String(format: "%.2f", speed))|\(text)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
