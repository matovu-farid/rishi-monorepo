import Foundation
import CryptoKit

/// Deterministic hash-based fake `BookEmbedder` for unit tests that don't
/// want to drag Core ML into the test binary.
///
/// Properties guaranteed:
///   - 384-dim output (matches `CoreMLMiniLMEmbedder`)
///   - same input -> same output across runs (SHA-256 seeded)
///   - L2-normalized (sum of squares = 1.0 within 1e-5)
///   - distinct inputs produce distinct outputs (with overwhelming probability;
///     SHA-256 collision space)
///
/// Explicitly NOT semantic — used only to verify wiring in Plan 25-05
/// (`USearchBookSearch`), Plan 25-07 / 25-09 (Responder), and Plan 25-12
/// (integration). Production embedding is `CoreMLMiniLMEmbedder`.
public struct IdentityEmbedder: BookEmbedder, Sendable {
    public init() {}

    public func embed(_ text: String) async throws -> [Float32] {
        let digest = SHA256.hash(data: Data(text.utf8))
        let bytes = Array(digest) // 32 bytes
        var vec = [Float32](repeating: 0, count: 384)
        // Spread the 32 hash bytes through 384 slots with a per-row shift so
        // identical bytes don't produce identical vector positions across rows.
        for i in 0..<384 {
            let byte = bytes[i % bytes.count]
            let row = i / bytes.count
            let shift = UInt8(row & 7)
            let mixed = Int16(Int8(bitPattern: byte)) ^ Int16(shift)
            vec[i] = Float32(mixed) / 128.0
        }
        let norm = sqrt(vec.reduce(Float32(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vec }
        return vec.map { $0 / norm }
    }

    public func prewarm() async {}
}
