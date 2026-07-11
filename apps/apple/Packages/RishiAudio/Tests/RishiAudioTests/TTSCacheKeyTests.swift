import Testing
import Foundation
import CryptoKit
@testable import RishiAudio

@Suite("TTSCacheKey")
struct TTSCacheKeyTests {
    // ----------------------------------------------------------------------------
    // Cross-runner symmetry constant: this exact canonical string and resulting hex
    // MUST also appear verbatim in workers/worker/src/audio-speech-cache.test.ts.
    // Canonical: "gpt-4o-mini-tts|alloy|1.00|hello world"
    // ----------------------------------------------------------------------------
    static let pinnedCanonical = "gpt-4o-mini-tts|alloy|1.00|hello world"
    static let pinnedText = "hello world"
    static let pinnedVoice = "alloy"
    static let pinnedSpeed = 1.0

    @Test("compute produces 64-char lowercase hex")
    func producesHex() {
        let hex = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.0)
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
    }

    @Test("identical inputs produce identical hex")
    func deterministic() {
        let a = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.0)
        let b = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.0)
        #expect(a == b)
    }

    @Test("different speed produces different hex")
    func speedSensitive() {
        let a = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.0)
        let b = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.5)
        #expect(a != b)
    }

    @Test("different voice produces different hex")
    func voiceSensitive() {
        let a = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.0)
        let b = TTSCacheKey.compute(text: "hello", voice: "nova", speed: 1.0)
        #expect(a != b)
    }

    @Test("different model produces different hex")
    func modelSensitive() {
        let a = TTSCacheKey.compute(text: "hello", voice: "alloy", model: "gpt-4o-mini-tts", speed: 1.0)
        let b = TTSCacheKey.compute(text: "hello", voice: "alloy", model: "gpt-4o", speed: 1.0)
        #expect(a != b)
    }

    @Test("speed 1 and 1.0 produce identical hex (canonicalization)")
    func speedCanonicalization() {
        // RESEARCH.md Pitfall 3 — would break symmetry if we used String(speed)
        let a = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1.0)
        let b = TTSCacheKey.compute(text: "hello", voice: "alloy", speed: 1)
        #expect(a == b)
    }

    @Test("pinned canonical string matches worker test")
    func pinnedCanonicalSymmetry() {
        // The helper's canonical string for these inputs MUST be byte-identical with
        // the worker test's PINNED_CANONICAL constant.
        let canonical = "\(TTSModelCatalog.defaultModel)|\(Self.pinnedVoice)|\(String(format: "%.2f", Self.pinnedSpeed))|\(Self.pinnedText)"
        #expect(canonical == Self.pinnedCanonical)

        // The hex MUST be byte-identical with the worker test's hex computed via
        // crypto.subtle.digest("SHA-256", new TextEncoder().encode(PINNED_CANONICAL)).
        let hex = TTSCacheKey.compute(text: Self.pinnedText, voice: Self.pinnedVoice, model: TTSModelCatalog.defaultModel, speed: Self.pinnedSpeed)
        #expect(hex.count == 64)

        // Sanity: recompute via the raw CryptoKit primitive against the pinned canonical and
        // assert the helper produces the same hex. This catches any future drift in the helper's
        // canonical formula without baking a fixed hex literal that would need manual updates.
        let directDigest = SHA256.hash(data: Data(Self.pinnedCanonical.utf8))
        let directHex = directDigest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == directHex)
    }
}
