import ReadiumShared

/// Creates the content tokenizer used by Readium's speech synthesizer.
///
/// Readium's default tokenizer uses sentence units. The reader speaks one
/// paragraph at a time instead, while retaining the locator context Readium
/// uses for highlighting and navigation.
public enum CustomTTSTokenizer {
    /// Builds a paragraph tokenizer using the publication's fallback language.
    /// Segment-level language attributes still take precedence, as handled by
    /// `makeTextContentTokenizer`.
    public static func tokenize(defaultLanguage: Language?) -> ContentTokenizer {
        makeTextContentTokenizer(
            defaultLanguage: defaultLanguage,
            contextSnippetLength: 50,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .paragraph, language: language)
            }
        )
    }
}
