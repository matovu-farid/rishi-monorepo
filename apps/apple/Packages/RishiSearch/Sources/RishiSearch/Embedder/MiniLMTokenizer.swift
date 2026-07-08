import Foundation

/// BERT WordPiece tokenizer for `sentence-transformers/all-MiniLM-L6-v2`.
///
/// Ported from the upstream Abhishek6353/AllMiniLML6V2-coreml repository
/// (Sources/Utils/MiniLMTokenizer.swift, MIT-licensed — see
/// `Resources/LICENSE-AllMiniLML6V2.txt`) with these local changes:
///
///   - hoisted to `internal struct` matching the Plan 25-04 interface
///     (`init(vocabURL:)`, `encode(_:)` returning `(inputIds, attentionMask)`)
///   - vocab loader takes a URL parameter rather than a bundle subpath, so
///     tests can hand in a URL resolved from `Bundle.module`
///   - `maxLength` defaults to 64 (the compiled sequence-length input shape
///     of our vendored `AllMiniLML6V2.mlmodel` — the upstream conversion
///     script's `seq_len=64` default)
///
/// Special token IDs (constants in BERT base uncased vocab):
///   `[PAD] = 0`, `[UNK] = 100`, `[CLS] = 101`, `[SEP] = 102`
struct MiniLMTokenizer: Sendable {
    struct Output: Sendable, Equatable {
        let inputIds: [Int32]      // length == maxLength, padded with [PAD]=0
        let attentionMask: [Int32] // length == maxLength, 1 for real tokens, 0 for pad
    }

    enum LoadError: Error, Equatable {
        case vocabUnreadable
        case vocabEmpty
    }

    private let tokenToId: [String: Int32]
    private let unkId: Int32
    private let clsId: Int32
    private let sepId: Int32
    private let padId: Int32
    let maxLength: Int

    static func defaultVocabURL() -> URL? {
        Bundle.module.url(forResource: "vocab", withExtension: "txt")
    }

    init(vocabURL: URL, maxLength: Int = 64) throws {
        guard let content = try? String(contentsOf: vocabURL, encoding: .utf8) else {
            throw LoadError.vocabUnreadable
        }
        var map: [String: Int32] = [:]
        // BERT vocab files are one token per line; line index == id. We keep
        // empty lines as valid entries since the upstream vocab uses the
        // empty-string slot in some positions — but never for the four
        // special tokens we care about.
        var idx: Int32 = 0
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                map[token] = idx
            }
            idx += 1
        }
        guard !map.isEmpty else { throw LoadError.vocabEmpty }
        self.tokenToId = map
        self.unkId = map["[UNK]"] ?? 100
        self.clsId = map["[CLS]"] ?? 101
        self.sepId = map["[SEP]"] ?? 102
        self.padId = map["[PAD]"] ?? 0
        self.maxLength = maxLength
    }

    func encode(_ text: String, maxLength override: Int? = nil) -> Output {
        let limit = override ?? maxLength

        // 1) Normalize (NFKC + lowercase + diacritic fold) — matches
        // BERT base uncased preprocessing.
        let normalized = Self.normalize(text)

        // 2) Basic tokenization: split on whitespace and punctuation.
        let basicTokens = Self.basicTokenize(normalized)

        // 3) WordPiece on each basic token, collecting subwords.
        var subwordIds: [Int32] = []
        subwordIds.reserveCapacity(basicTokens.count * 2)
        for token in basicTokens {
            wordPieceTokenize(token: token, into: &subwordIds)
        }

        // 4) Prepend [CLS], append [SEP], truncate, pad.
        let bodyCap = limit - 2 // reserve slots for [CLS] and [SEP]
        let body = (subwordIds.count > bodyCap) ? Array(subwordIds.prefix(bodyCap)) : subwordIds

        var ids: [Int32] = [clsId]
        ids.append(contentsOf: body)
        ids.append(sepId)

        // Pad
        var mask: [Int32] = Array(repeating: 1, count: ids.count)
        if ids.count < limit {
            let padCount = limit - ids.count
            ids.append(contentsOf: Array(repeating: padId, count: padCount))
            mask.append(contentsOf: Array(repeating: 0, count: padCount))
        }
        return Output(inputIds: ids, attentionMask: mask)
    }

    // MARK: - Normalization

    private static func normalize(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let lower = nfkc.lowercased()
        // strip accents/diacritics + width fold
        let folded = lower.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: .current
        )
        // collapse repeated whitespace
        let parts = folded.split { $0.isWhitespace }.map(String.init)
        return parts.joined(separator: " ")
    }

    private static func basicTokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for scalar in text.unicodeScalars {
            let ch = Character(scalar)
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || ch == "'" || ch == "\u{2019}" /* ’ */ || ch == "#" || ch == "@" {
                current.append(ch)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flush()
            } else {
                // punctuation / symbol: each one becomes its own token
                flush()
                tokens.append(String(ch))
            }
        }
        flush()
        return tokens.filter { !$0.isEmpty }
    }

    // MARK: - WordPiece

    /// Greedy longest-match WordPiece. Continuation pieces use the "##" prefix
    /// shipped in the BERT vocab. If no decomposition is found, emit a single
    /// [UNK] for the whole basic token.
    private func wordPieceTokenize(token: String, into output: inout [Int32]) {
        // Direct hit short-circuit.
        if let directId = tokenToId[token] {
            output.append(directId)
            return
        }

        let chars = Array(token)
        var start = 0
        var pieces: [Int32] = []
        var failed = false

        while start < chars.count {
            var end = chars.count
            var foundId: Int32? = nil
            while start < end {
                let slice = String(chars[start..<end])
                let candidate = (start > 0) ? "##" + slice : slice
                if let id = tokenToId[candidate] {
                    foundId = id
                    break
                }
                end -= 1
            }
            guard let id = foundId else {
                failed = true
                break
            }
            pieces.append(id)
            start = end
        }

        if failed || pieces.isEmpty {
            output.append(unkId)
        } else {
            output.append(contentsOf: pieces)
        }
    }
}
