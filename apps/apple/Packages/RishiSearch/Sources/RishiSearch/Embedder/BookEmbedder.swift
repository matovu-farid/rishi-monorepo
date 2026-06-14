import Foundation

/// Internal seam used by `USearchBookSearch` (Plan 25-05) and pre-warmed by
/// `VoiceSession.start` (Plan 25-10). Two conformers ship from this plan:
///
///   - `CoreMLMiniLMEmbedder` — production; loads the vendored Core ML port
///     of `sentence-transformers/all-MiniLM-L6-v2` from `Bundle.module`.
///   - `IdentityEmbedder` — deterministic hash-based fake for tests in
///     Plans 25-07 / 25-09 / 25-12 that do not want to pay Core ML cold-load.
///
/// Output vectors are 384-dim and L2-normalized so cosine similarity over
/// USearch reduces to dot product. Implementations MUST normalize before
/// returning; the contract is "ready to plug into `index.add(...)`".
protocol BookEmbedder: Sendable {
    /// Embed one input string into a 384-element L2-normalized vector.
    /// Implementations may truncate input above the model's sequence
    /// length (64 word pieces for `all-MiniLM-L6-v2` as vendored).
    func embed(_ text: String) async throws -> [Float32]

    /// Idempotent prewarm — loads the model + tokenizer if not already
    /// loaded. Plan 25-10 calls this at `VoiceSession.start` so the first
    /// real `embed(...)` doesn't pay the ~500 ms Core ML cold-load.
    func prewarm() async
}
