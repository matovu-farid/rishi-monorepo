import Foundation
import ReadiumShared

/// Creates the content tokenizer used by Readium's speech synthesizer.
///
/// Readium's default tokenizer uses sentence units. The reader speaks EPUB
/// content one paragraph at a time by default, while retaining the locator
/// context Readium uses for highlighting and navigation. PDF playback may
/// opt into sentence units.
public enum CustomTTSTokenizer {
    private static let pdfSentenceChunkCapacity = 400

    public enum Granularity: Sendable, Equatable {
        case paragraph
        case sentence
    }

    /// Builds a tokenizer using the publication's fallback language.
    /// Segment-level language attributes still take precedence, as handled by
    /// `makeTextContentTokenizer`.
    public static func tokenize(
        defaultLanguage: Language?,
        granularity: Granularity = .paragraph
    ) -> ContentTokenizer {
        let tokenizer = makeTextContentTokenizer(
            defaultLanguage: defaultLanguage,
            contextSnippetLength: 50,
            textTokenizerFactory: { language in
                guard granularity == .sentence else {
                    return makeDefaultTextTokenizer(unit: .paragraph, language: language)
                }
                return Self.makeLineBreakTolerantSentenceTokenizer(language: language)
            }
        )

        guard granularity == .sentence else {
            return tokenizer
        }

        return { content in
            let tokenized = try tokenizer(content)
            return tokenized.map { element in
                guard var textContent = element as? TextContentElement else {
                    return element
                }

                textContent.segments = Self.packPDFSentences(textContent.segments)
                return textContent
            }
        }
    }

    /// Groups complete PDF sentences into paragraph-sized chunks without
    /// changing the sentence tokenizer or the EPUB paragraph path.
    private static func packPDFSentences(
        _ sentences: [TextContentElement.Segment]
    ) -> [TextContentElement.Segment] {
        var chunks: [TextContentElement.Segment] = []
        var current: TextContentElement.Segment?

        for sentence in sentences {
            guard var chunk = current else {
                current = sentence
                continue
            }

            let packedText = "\(chunk.text) \(sentence.text)"
            guard packedText.count <= pdfSentenceChunkCapacity else {
                chunks.append(chunk)
                current = sentence
                continue
            }

            chunk.text = packedText
            chunk.locator = chunk.locator.copy(text: {
                $0.highlight = packedText
                // Keep the locator's surrounding context aligned with the
                // complete packed range while retaining the first sentence's
                // href and position as the authoritative anchor.
                $0.after = sentence.locator.text.after
            })
            current = chunk
        }

        if let current {
            chunks.append(current)
        }
        return chunks
    }

    /// PDF text extraction retains visual line breaks inside a page. Natural
    /// Language can treat those breaks as sentence boundaries, even when the
    /// sentence continues on the next line. Normalize only for tokenization,
    /// preserving UTF-16 offsets so the returned ranges still address the
    /// original text and its Readium highlight locator.
    private static func makeLineBreakTolerantSentenceTokenizer(
        language: Language?
    ) -> TextTokenizer {
        let sentenceTokenizer = makeDefaultTextTokenizer(unit: .sentence, language: language)

        return { text in
            let tokenizationText = text
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let ranges = try sentenceTokenizer(tokenizationText)

            return ranges.compactMap { range in
                let lowerOffset = range.lowerBound.utf16Offset(in: tokenizationText)
                let upperOffset = range.upperBound.utf16Offset(in: tokenizationText)
                let lower = String.Index(utf16Offset: lowerOffset, in: text)
                let upper = String.Index(utf16Offset: upperOffset, in: text)
                return lower ..< upper
            }
        }
    }
}
