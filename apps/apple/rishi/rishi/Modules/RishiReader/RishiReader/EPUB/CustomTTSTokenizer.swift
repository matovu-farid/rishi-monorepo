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

    public enum PDFLocatorMetadata {
        public static let selectionStartUTF16 = "rishiPDFSelectionStartUTF16"
        public static let paragraphStartUTF16 = "rishiParagraphStartUTF16"
        public static let utteranceOrdinal = "rishiUtteranceOrdinal"
        public static let sourceOutputSpans = "rishiSourceOutputSpans"
    }

    /// One-shot target used when Readium starts a fresh PDF synthesizer. Page
    /// numbers are 1-based; offsets and utterance ordinals are page-local.
    public final class PDFNarrationTokenizationCursor: @unchecked Sendable {
        public struct Snapshot: Sendable, Equatable {
            public let targetPage: Int
            public let startUTF16Offset: Int?
            public let utteranceOrdinal: Int?
            public let paragraphStartUTF16: Int?
        }

        private let lock = NSLock()
        private let snapshot: Snapshot
        private var consumed = false

        public init(
            targetPage: Int,
            startUTF16Offset: Int? = nil,
            utteranceOrdinal: Int? = nil,
            paragraphStartUTF16: Int? = nil
        ) {
            snapshot = Snapshot(
                targetPage: targetPage,
                startUTF16Offset: startUTF16Offset,
                utteranceOrdinal: utteranceOrdinal,
                paragraphStartUTF16: paragraphStartUTF16
            )
        }

        public func consume(forPage page: Int) -> Snapshot? {
            lock.withLock {
                guard !consumed, page == snapshot.targetPage else { return nil }
                consumed = true
                return snapshot
            }
        }
    }

    /// Shared one-shot selection state for the lifetime of a PDF Readium
    /// tokenizer factory. Readium asks that factory for a new tokenizer on
    /// each page, so this gate must be created by the factory owner and
    /// passed to every returned `ContentTokenizer`.
    public final class PDFNarrationSelectionGate: @unchecked Sendable {
        private let lock = NSLock()
        private let expectedStartingPage: Int?
        private var startingPage: Int?
        private var consumed = false

        public init(startingPage: Int? = nil) {
            expectedStartingPage = startingPage
        }

        /// Claims the selection exactly once. With no known start page, the
        /// first page presented becomes the selected page. A retry of that
        /// page and all later pages return `false` after consumption.
        public func claimSelection(forPage page: Int) -> Bool {
            lock.withLock {
                guard !consumed else { return false }
                if let expectedStartingPage {
                    guard expectedStartingPage == page else { return false }
                } else if let startingPage {
                    guard startingPage == page else { return false }
                } else {
                    startingPage = page
                }
                consumed = true
                return true
            }
        }
    }

    /// Returns the first content element with text before a selection removed.
    /// Readium's HTML iterator and PDF iterator both begin at a containing
    /// element/page, so a selection start needs this small text-level trim to
    /// avoid replaying the passage before the user's selected position.
    /// Returns `nil` when the selection cannot be located in the element.
    static func trimming(
        _ content: ContentElement,
        before selection: Locator.Text
    ) -> ContentElement? {
        guard let textContent = content as? TextContentElement,
              let highlight = selection.highlight,
              !highlight.isEmpty,
              let fullText = textContent.text,
              !fullText.isEmpty
        else { return nil }

        let selectionRange: Range<String.Index>?
        if let before = selection.before,
           let contextualRange = fullText.range(of: before + highlight)
        {
            selectionRange = contextualRange
        } else {
            selectionRange = fullText.range(of: highlight)
        }
        guard let selectionRange else { return nil }
        guard selectionRange.lowerBound != fullText.startIndex else {
            return content
        }

        let remainingText = String(fullText[selectionRange.lowerBound...])
        guard !remainingText.isEmpty else { return nil }

        let sourceSegment = textContent.segments.first
        let locator = textContent.locator.copy(text: { text in
            text = Locator.Text(highlight: remainingText)
        })
        let segment = TextContentElement.Segment(
            locator: locator,
            text: remainingText,
            attributes: sourceSegment?.attributes ?? []
        )
        return TextContentElement(
            locator: locator,
            role: textContent.role,
            segments: [segment],
            attributes: textContent.attributes
        )
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

    /// PDF-specific tokenizer. It splits a single Readium page element at
    /// verified paragraph ranges, sentence-tokenizes each paragraph
    /// independently, then packs sentences without crossing paragraph
    /// boundaries. Exact source/output UTF-16 spans are retained in locator
    /// metadata for selection starts and repeat/skip restarts.
    public static func tokenizePDF(
        defaultLanguage: Language?,
        paragraphMap: PDFNarrationParagraphMap,
        cursor: PDFNarrationTokenizationCursor? = nil,
        selectionText: Locator.Text? = nil,
        selectionStartUTF16Offset: Int? = nil,
        selectionGate: PDFNarrationSelectionGate? = nil
    ) -> ContentTokenizer {
        tokenizePDF(
            defaultLanguage: defaultLanguage,
            paragraphRanges: { page, text in paragraphMap.paragraphRanges(page: page, pageText: text) },
            cursor: cursor,
            selectionText: selectionText,
            selectionStartUTF16Offset: selectionStartUTF16Offset,
            selectionGate: selectionGate
        )
    }

    /// Closure-backed overload for deterministic tests and alternate
    /// paragraph-range providers.
    static func tokenizePDF(
        defaultLanguage: Language?,
        paragraphRanges: @escaping (Int, String) -> PDFReadAloudParagraphs.ParagraphRangeResult,
        cursor: PDFNarrationTokenizationCursor? = nil,
        selectionText: Locator.Text? = nil,
        selectionStartUTF16Offset: Int? = nil,
        selectionGate: PDFNarrationSelectionGate? = nil
    ) -> ContentTokenizer {
        let sentenceTokenizer = Self.makeLineBreakTolerantSentenceTokenizer(language: defaultLanguage)
        let pageSelectionGate = selectionGate ?? PDFNarrationSelectionGate()

        return { content in
            guard var pageContent = content as? TextContentElement,
                  let fullText = pageContent.text,
                  let page = pageContent.locator.locations.page
            else { return [content] }

            let locatorSelectionOffset = pageContent.locator.locations.otherLocations[
                PDFLocatorMetadata.selectionStartUTF16
            ]?.integer

            // Readium copies the resource locator's custom locations onto
            // every page. Clear our page-local tags before deriving this
            // page's verified paragraph/utterance/span metadata.
            pageContent.locator = Self.removingPDFNarrationMetadata(from: pageContent.locator)

            let paragraphResult = paragraphRanges(page, fullText)
            let paragraphs: [(Range<Int>, Int?)]
            switch paragraphResult {
            case let .available(ranges):
                paragraphs = ranges.map { ($0, $0.lowerBound) }
            case .unavailable:
                paragraphs = [(0..<fullText.utf16.count, nil)]
            }

            let sourceSegment = pageContent.segments.first
            let attributes = sourceSegment?.attributes ?? []
            var canonical: [SourcedSegment] = []
            for (paragraphRange, paragraphStart) in paragraphs {
                guard let paragraphText = Self.substring(fullText, utf16Range: paragraphRange) else { continue }
                let paragraphLocator = pageContent.locator.copy(text: {
                    $0 = Locator.Text(highlight: paragraphText)
                })
                let paragraphSegment = TextContentElement.Segment(
                    locator: paragraphLocator,
                    text: paragraphText,
                    attributes: attributes
                )

                guard let sentenceRanges = try? sentenceTokenizer(paragraphText) else { continue }
                var sentences: [SourcedSegment] = []
                for range in sentenceRanges {
                    let text = String(paragraphText[range])
                    guard !text.isEmpty else { continue }
                    let lower = range.lowerBound.utf16Offset(in: paragraphText)
                    let upper = range.upperBound.utf16Offset(in: paragraphText)
                    let sourceStart = paragraphRange.lowerBound + lower
                    let sourceEnd = paragraphRange.lowerBound + upper
                    sentences.append(SourcedSegment(
                        text: text,
                        spans: [SourceOutputSpan(
                            source: sourceStart..<sourceEnd,
                            output: 0..<text.utf16.count
                        )],
                        locator: Self.locator(
                            from: paragraphSegment.locator,
                            text: text,
                            in: paragraphText,
                            range: range,
                            paragraphStart: paragraphStart
                        ),
                        attributes: paragraphSegment.attributes
                    ))
                }
                canonical.append(contentsOf: Self.pack(sentences))
            }

            // For pages where geometry could not be verified, keep speech
            // moving with the full page tokenizer output, but do not claim a
            // paragraph start that Repeat cannot safely honor.
            for ordinal in canonical.indices {
                var locations = canonical[ordinal].locator.locations
                locations.otherLocations[PDFLocatorMetadata.utteranceOrdinal] = .integer(ordinal)
                canonical[ordinal].locator = canonical[ordinal].locator.copy(locations: { $0 = locations })
            }

            let selectedCursor = cursor?.consume(forPage: page)
            let selectionOffset: Int?
            if let cursorOffset = selectedCursor?.startUTF16Offset {
                selectionOffset = cursorOffset
            } else if selectedCursor == nil,
                      cursor == nil,
                      let selectionText,
                      let highlight = selectionText.highlight,
                      !highlight.isEmpty,
                      pageSelectionGate.claimSelection(forPage: page)
            {
                let preferredOffset = selectionStartUTF16Offset ?? locatorSelectionOffset
                guard let resolved = Self.selectionOffset(
                    in: fullText,
                    selection: selectionText,
                    preferredUTF16Offset: preferredOffset
                ) else {
                    return []
                }
                selectionOffset = resolved
            } else {
                selectionOffset = nil
            }
            if let selectedCursor {
                if let paragraphStart = selectedCursor.paragraphStartUTF16 {
                    guard let paragraphIndex = canonical.firstIndex(where: { segment in
                        segment.locator.locations.otherLocations[PDFLocatorMetadata.paragraphStartUTF16]?.integer == paragraphStart
                    }) else { return [] }
                    canonical = Array(canonical[paragraphIndex...])
                }
                if let ordinal = selectedCursor.utteranceOrdinal {
                    canonical.removeAll { ($0.locator.locations.otherLocations[PDFLocatorMetadata.utteranceOrdinal]?.integer ?? -1) < ordinal }
                }
            }
            if let selectionOffset {
                canonical = Self.trim(canonical, startingAt: selectionOffset)
            }

            pageContent.segments = canonical.map(\.asReadiumSegment)
            return [pageContent]
        }
    }

    private static func removingPDFNarrationMetadata(from locator: Locator) -> Locator {
        locator.copy(locations: { locations in
            locations.otherLocations.removeValue(forKey: PDFLocatorMetadata.selectionStartUTF16)
            locations.otherLocations.removeValue(forKey: PDFLocatorMetadata.paragraphStartUTF16)
            locations.otherLocations.removeValue(forKey: PDFLocatorMetadata.utteranceOrdinal)
            locations.otherLocations.removeValue(forKey: PDFLocatorMetadata.sourceOutputSpans)
        })
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

    private struct SourceOutputSpan {
        let source: Range<Int>
        let output: Range<Int>
    }

    private struct SourcedSegment {
        var text: String
        var spans: [SourceOutputSpan]
        var locator: Locator
        let attributes: [ContentAttribute]

        var asReadiumSegment: TextContentElement.Segment {
            TextContentElement.Segment(locator: locator, text: text, attributes: attributes)
        }
    }

    private static func pack(_ sentences: [SourcedSegment]) -> [SourcedSegment] {
        var packed: [SourcedSegment] = []
        for sentence in sentences {
            guard var current = packed.popLast() else {
                packed.append(sentence)
                continue
            }
            let merged = "\(current.text) \(sentence.text)"
            guard merged.count <= pdfSentenceChunkCapacity else {
                packed.append(current)
                packed.append(sentence)
                continue
            }
            let outputShift = current.text.utf16.count + 1
            current.text = merged
            current.spans.append(contentsOf: sentence.spans.map { span in
                SourceOutputSpan(
                    source: span.source,
                    output: (span.output.lowerBound + outputShift)..<(span.output.upperBound + outputShift)
                )
            })
            current.locator = current.locator.copy(text: {
                $0.highlight = merged
                $0.after = sentence.locator.text.after
            })
            packed.append(current)
        }

        return packed.map { segment in
            var result = segment
            var locations = result.locator.locations
            locations.otherLocations[PDFLocatorMetadata.sourceOutputSpans] = .array(
                result.spans.map { span in
                    .object([
                        "sourceStartUTF16": .integer(span.source.lowerBound),
                        "sourceEndUTF16": .integer(span.source.upperBound),
                        "outputStartUTF16": .integer(span.output.lowerBound),
                        "outputEndUTF16": .integer(span.output.upperBound),
                    ])
                }
            )
            result.locator = result.locator.copy(locations: { $0 = locations })
            return result
        }
    }

    private static func locator(
        from base: Locator,
        text: String,
        in paragraph: String,
        range: Range<String.Index>,
        paragraphStart: Int?
    ) -> Locator {
        let lower = range.lowerBound.utf16Offset(in: paragraph)
        let upper = range.upperBound.utf16Offset(in: paragraph)
        let nsText = paragraph as NSString
        let beforeStart = max(0, lower - 50)
        let afterEnd = min(nsText.length, upper + 50)
        let before = beforeStart < lower
            ? nsText.substring(with: NSRange(location: beforeStart, length: lower - beforeStart))
            : nil
        let after = upper < afterEnd
            ? nsText.substring(with: NSRange(location: upper, length: afterEnd - upper))
            : nil
        return base.copy(
            locations: { locations in
                if let paragraphStart {
                    locations.otherLocations[PDFLocatorMetadata.paragraphStartUTF16] = .integer(paragraphStart)
                }
            },
            text: {
                $0 = Locator.Text(after: after, before: before, highlight: text)
            }
        )
    }

    private static func substring(_ value: String, utf16Range: Range<Int>) -> String? {
        guard utf16Range.lowerBound >= 0,
              utf16Range.upperBound <= value.utf16.count,
              utf16Range.lowerBound <= utf16Range.upperBound
        else { return nil }
        let lower = String.Index(utf16Offset: utf16Range.lowerBound, in: value)
        let upper = String.Index(utf16Offset: utf16Range.upperBound, in: value)
        guard lower <= upper else { return nil }
        return String(value[lower..<upper])
    }

    private static func uniqueSelectionOffset(in text: String, selection: Locator.Text) -> Int? {
        guard let highlight = selection.highlight, !highlight.isEmpty else { return nil }
        let context = (selection.before ?? "") + highlight
        guard let range = text.range(of: context),
              text[range.upperBound...].range(of: context) == nil
        else { return nil }
        let contextStart = range.lowerBound.utf16Offset(in: text)
        return contextStart + (selection.before ?? "").utf16.count
    }

    private static func selectionOffset(
        in text: String,
        selection: Locator.Text,
        preferredUTF16Offset: Int?
    ) -> Int? {
        guard let highlight = selection.highlight, !highlight.isEmpty else { return nil }
        let highlightLength = highlight.utf16.count
        if let preferredUTF16Offset,
           preferredUTF16Offset >= 0,
           highlightLength <= text.utf16.count,
           preferredUTF16Offset <= text.utf16.count - highlightLength,
           let selectedText = substring(
               text,
               utf16Range: preferredUTF16Offset..<(preferredUTF16Offset + highlightLength)
           ),
           selectedText == highlight {
            return preferredUTF16Offset
        }
        return uniqueSelectionOffset(in: text, selection: selection)
    }

    private static func trim(_ segments: [SourcedSegment], startingAt offset: Int) -> [SourcedSegment] {
        guard offset >= 0 else { return [] }
        for index in segments.indices {
            guard let span = segments[index].spans.first(where: { $0.source.upperBound > offset }) else { continue }
            let outputOffset = offset < span.source.lowerBound
                ? span.output.lowerBound
                : span.output.lowerBound + (offset - span.source.lowerBound)
            guard let suffix = substring(segments[index].text, utf16Range: outputOffset..<segments[index].text.utf16.count) else {
                return []
            }
            guard !suffix.isEmpty else { continue }
            var result = Array(segments[index...])
            result[0].text = suffix
            result[0].locator = result[0].locator.copy(text: { $0.highlight = suffix })
            return result
        }
        return []
    }
}
