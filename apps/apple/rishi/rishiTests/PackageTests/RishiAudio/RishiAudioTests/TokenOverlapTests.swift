@testable import rishi
import Testing
import Foundation


@Suite("TokenOverlap")
struct TokenOverlapTests {
    // The metric is symmetric Jaccard over normalized token SETS (RESEARCH §5.3):
    // lowercase -> strip non-alphanumerics -> collapse whitespace -> split on spaces.

    @Test("identical strings score 1.0")
    func identical() {
        let score = TokenOverlap.score("the quick brown fox", against: "the quick brown fox")
        #expect(abs(score - 1.0) < 0.0001)
    }

    @Test("punctuation and case differences normalize to 1.0")
    func punctuationAndCaseNormalized() {
        let score = TokenOverlap.score("The quick brown fox.", against: "the quick brown fox")
        #expect(abs(score - 1.0) < 0.0001)
    }

    @Test("disjoint token sets score 0.0")
    func disjoint() {
        let score = TokenOverlap.score("the quick brown fox", against: "a slow green turtle")
        #expect(abs(score - 0.0) < 0.0001)
    }

    @Test("realistic STT drift clears the 0.6 threshold")
    func sttDriftClearsThreshold() {
        let score = TokenOverlap.score(
            "the quick brown fox jumps over the lazy dog",
            against: "the quick brown fox jumped over a lazy dog"
        )
        #expect(score >= 0.6)
    }

    @Test("partial overlap lands strictly between 0 and 1")
    func partialOverlap() {
        let score = TokenOverlap.score("alpha beta gamma", against: "beta gamma delta")
        #expect(score > 0.0)
        #expect(score < 1.0)
    }

    @Test("empty inputs score 0.0 without trapping")
    func emptyInputs() {
        #expect(abs(TokenOverlap.score("", against: "") - 0.0) < 0.0001)
        #expect(abs(TokenOverlap.score("hello", against: "") - 0.0) < 0.0001)
    }
}
