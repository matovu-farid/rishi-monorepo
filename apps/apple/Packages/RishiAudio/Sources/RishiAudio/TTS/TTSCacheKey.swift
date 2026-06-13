import Foundation
import CryptoKit

/// Pure SHA-256 hex helper for the TTS audio cache.
///
/// MUST stay byte-for-byte symmetric with the worker-side `ttsCacheKey` helper in
/// `workers/worker/src/index.ts`. The pinned canonical string `"tts-1|alloy|1.00|hello world"`
/// is asserted to produce the same hex by both this package's TTSCacheKeyTests AND the worker's
/// `audio-speech-cache.test.ts`. See Phase 22 RESEARCH.md Pitfall 3 (speed canonicalization).
public enum TTSCacheKey {
    /// Computes the cache key for a TTS request.
    ///
    /// - Parameters:
    ///   - text: Synthesis text, raw (not normalised).
    ///   - voice: One of the worker's allowlist (alloy, echo, fable, onyx, nova, shimmer).
    ///   - speed: Float speed, formatted with `%.2f` for canonicalization.
    /// - Returns: 64-character lowercase hex SHA-256 digest.
    public static func compute(text: String, voice: String, speed: Double) -> String {
        let canonical = "tts-1|\(voice)|\(String(format: "%.2f", speed))|\(text)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
