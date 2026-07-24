import ReadiumShared

/// Creates the content tokenizer used by Readium's speech synthesizer.
///
/// Readium's default tokenizer uses sentence units. The reader speaks EPUB
/// content one paragraph at a time by default, while retaining the locator
/// context Readium uses for highlighting and navigation. PDF playback may
/// opt into sentence units.
public enum CustomTTSTokenizer {
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
        makeTextContentTokenizer(
            defaultLanguage: defaultLanguage,
            contextSnippetLength: 50,
            textTokenizerFactory: { language in
                guard granularity == .sentence else {
                    return makeDefaultTextTokenizer(unit: .paragraph, language: language)
                }
                return Self.makeLineBreakTolerantSentenceTokenizer(language: language)
            }
        )
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
