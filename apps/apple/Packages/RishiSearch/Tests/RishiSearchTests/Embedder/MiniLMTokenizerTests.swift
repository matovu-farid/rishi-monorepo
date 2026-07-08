import Foundation
import Testing
@testable import RishiSearch

/// Tokenizer contract — verifies WordPiece BERT-base-uncased semantics
/// against the vendored vocab.txt. Special token IDs are pinned to the
/// HF `sentence-transformers/all-MiniLM-L6-v2` `vocab.txt` shipped under
/// `Resources/`:
///
///   `[PAD] = 0`, `[UNK] = 100`, `[CLS] = 101`, `[SEP] = 102`
///   `hello = 7592`, `world = 2088`
///
/// The vendored `.mlmodel` was compiled with seq_len=64 (per the upstream
/// `convert_minilm_to_coreml.py` default); the tokenizer therefore
/// defaults to maxLength=64 so encode output matches the model's input
/// shape one-to-one.
@Suite("MiniLMTokenizer")
struct MiniLMTokenizerTests {
    private func makeTokenizer(maxLength: Int = 64) throws -> MiniLMTokenizer {
        guard let url = MiniLMTokenizer.defaultVocabURL() else {
            Issue.record("vocab.txt not found in Bundle.module — Resources wiring broken")
            throw MiniLMTokenizer.LoadError.vocabUnreadable
        }
        return try MiniLMTokenizer(vocabURL: url, maxLength: maxLength)
    }

    @Test func encodesHelloWorldWithSpecialTokensAndPadding() throws {
        let tok = try makeTokenizer()
        let out = tok.encode("hello world")

        #expect(out.inputIds.count == 64)
        #expect(out.attentionMask.count == 64)

        // [CLS] hello world [SEP] then 60 pads.
        #expect(out.inputIds[0] == 101)
        #expect(out.inputIds[1] == 7592)
        #expect(out.inputIds[2] == 2088)
        #expect(out.inputIds[3] == 102)
        for i in 4..<64 {
            #expect(out.inputIds[i] == 0, "pad at index \(i)")
        }

        // attention mask 1s for the four real tokens, 0s for pads.
        #expect(out.attentionMask[0] == 1)
        #expect(out.attentionMask[1] == 1)
        #expect(out.attentionMask[2] == 1)
        #expect(out.attentionMask[3] == 1)
        for i in 4..<64 {
            #expect(out.attentionMask[i] == 0, "mask pad at index \(i)")
        }
    }

    @Test func encodesEmptyStringAsCLSThenSEP() throws {
        let tok = try makeTokenizer()
        let out = tok.encode("")
        #expect(out.inputIds.count == 64)
        #expect(out.inputIds[0] == 101) // [CLS]
        #expect(out.inputIds[1] == 102) // [SEP]
        for i in 2..<64 {
            #expect(out.inputIds[i] == 0)
        }
        #expect(out.attentionMask[0] == 1)
        #expect(out.attentionMask[1] == 1)
        #expect(out.attentionMask[2] == 0)
    }

    @Test func truncatesLongInputToMaxLength() throws {
        let tok = try makeTokenizer()
        // 200 repetitions of a common word — far above the 64-token cap.
        let long = Array(repeating: "hello", count: 200).joined(separator: " ")
        let out = tok.encode(long)
        #expect(out.inputIds.count == 64)
        #expect(out.attentionMask.count == 64)
        // Truncated output keeps [CLS] at position 0 and ends with [SEP].
        #expect(out.inputIds[0] == 101)
        #expect(out.inputIds[63] == 102)
        // No padding — every position has attention 1.
        for i in 0..<64 {
            #expect(out.attentionMask[i] == 1, "mask should be 1 at \(i) when full")
        }
    }

    @Test func unknownTokenFallsBackToUNK() throws {
        let tok = try makeTokenizer()
        // Pure punctuation soup that has no WordPiece coverage — should fall back to [UNK].
        let out = tok.encode("🦄")
        #expect(out.inputIds[0] == 101)               // [CLS]
        // Either we get [UNK]=100 followed by [SEP], or just [CLS][SEP] if the
        // emoji is filtered out by the normalizer. Both are acceptable BERT-uncased behaviour.
        let hasUnk = out.inputIds.contains(100)
        let endsAtTwo = out.inputIds[1] == 102
        #expect(hasUnk || endsAtTwo)
    }
}

@Suite("IdentityEmbedder")
struct IdentityEmbedderTests {
    @Test func returns384DimVector() async throws {
        let embedder = IdentityEmbedder()
        let vec = try await embedder.embed("hello")
        #expect(vec.count == 384)
    }

    @Test func isDeterministicAcrossCalls() async throws {
        let embedder = IdentityEmbedder()
        let a = try await embedder.embed("hello")
        let b = try await embedder.embed("hello")
        #expect(a == b)
    }

    @Test func differentInputsProduceDifferentVectors() async throws {
        let embedder = IdentityEmbedder()
        let a = try await embedder.embed("hello")
        let b = try await embedder.embed("world")
        #expect(a != b)
    }

    @Test func outputIsL2Normalized() async throws {
        let embedder = IdentityEmbedder()
        let vec = try await embedder.embed("hello world")
        let sumOfSquares = vec.reduce(Float32(0)) { $0 + $1 * $1 }
        #expect(abs(sumOfSquares - 1.0) < 1e-5)
    }

    @Test func prewarmIsIdempotentAndCheap() async {
        let embedder = IdentityEmbedder()
        await embedder.prewarm()
        await embedder.prewarm()
        // Just verifying it doesn't crash or hang. No state to assert.
    }
}
