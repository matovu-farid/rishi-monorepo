import Foundation

/// Deterministic, Foundation-only fuzzy text-comparison metric for the
/// TTS->STT round-trip (RESEARCH §5.3). STT output drifts from the source
/// text (punctuation, casing, tense, dropped articles), so an exact-match
/// assertion is too brittle. `TokenOverlap` normalizes both sides and reports
/// a symmetric similarity in `[0, 1]` so the round-trip can assert
/// "close enough" via a threshold (~0.6).
///
/// The metric is **Jaccard similarity over normalized token SETS**:
/// `|A ∩ B| / |A ∪ B|`. It is symmetric (`score(a, b) == score(b, a)`),
/// returns `1.0` for identical token sets, `0.0` for disjoint sets, and a
/// value strictly between for partial overlap. Multiplicity is intentionally
/// ignored — STT rarely repeats words spuriously, and set semantics keep the
/// metric simple and stable.
public enum TokenOverlap {

    /// Symmetric Jaccard similarity of the normalized token sets of `a` and `b`.
    /// Returns `0.0` when either side normalizes to an empty token set.
    public static func score(_ a: String, against b: String) -> Double {
        let setA = normalize(a)
        let setB = normalize(b)
        if setA.isEmpty || setB.isEmpty { return 0.0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    /// Normalize to a token set: lowercase, replace every non-alphanumeric
    /// character with a space, collapse runs of whitespace, split on spaces.
    private static func normalize(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let cleaned = String(scalars)
        let tokens = cleaned.split(separator: " ").map(String.init)
        return Set(tokens)
    }
}
