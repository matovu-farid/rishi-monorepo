@testable import rishi
import Foundation
import ReadiumShared
import Testing


@Suite("Custom TTS tokenizer")
struct CustomTTSTokenizerTests {
    @Test("packs PDF sentences under the character capacity")
    func packsSentencesUnderCapacity() throws {
        let content = makeTextContent("First sentence. Second sentence.")

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "First sentence. Second sentence.",
        ])
    }

    @Test("flushes before a sentence that would exceed the capacity")
    func flushesBeforeSentenceExceedsCapacity() throws {
        let first = String(repeating: "a", count: 198) + "."
        let second = String(repeating: "b", count: 198) + "."
        let third = "Final sentence."
        let content = makeTextContent("\(first) \(second) \(third)")

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "\(first) \(second)",
            third,
        ])
    }

    @Test("keeps an oversized sentence as a standalone chunk")
    func keepsOversizedSentenceStandalone() throws {
        let oversized = String(repeating: "x", count: 400) + "."
        let content = makeTextContent("\(oversized) Short sentence.")

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            oversized,
            "Short sentence.",
        ])
    }

    @Test("preserves multiline text and the first sentence locator highlight")
    func preservesPackedLocatorHighlight() throws {
        let first = "First sentence continues across\nvisual lines."
        let second = "Second sentence."
        let content = makeTextContent("\(first) \(second)")

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)
        let packed = try #require(textContent.segments.first)

        #expect(packed.text == "\(first) \(second)")
        #expect(packed.locator.text.highlight == packed.text)
    }

    @Test("uses paragraph granularity by default")
    func defaultsToParagraphGranularity() throws {
        let content = makeTextContent(
            "First sentence. Second sentence."
        )

        let tokenized = try CustomTTSTokenizer.tokenize(defaultLanguage: Language("en"))(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "First sentence. Second sentence.",
        ])
    }

    @Test("trims the first content element before the selected position")
    func trimsBeforeSelection() throws {
        let content = makeTextContent("Before the selection. Selected text continues here.")
        let trimmed = try #require(
            CustomTTSTokenizer.trimming(
                content,
                before: Locator.Text(
                    before: "Before the selection. ",
                    highlight: "Selected"
                )
            ) as? TextContentElement
        )

        #expect(trimmed.text == "Selected text continues here.")
        #expect(trimmed.segments.first?.locator.text.highlight == trimmed.text)
    }

    @Test("packs sentences when sentence granularity is requested")
    func packsSentencesWhenRequested() throws {
        let content = makeTextContent(
            "First sentence. Second sentence."
        )

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "First sentence. Second sentence.",
        ])
    }

    @Test("keeps a sentence together across PDF line breaks")
    func keepsSentenceAcrossLineBreaks() throws {
        let content = makeTextContent(
            "This sentence continues across\nvisual lines without ending. Next sentence."
        )

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "This sentence continues across\nvisual lines without ending. Next sentence.",
        ])
        #expect(textContent.segments[0].locator.text.highlight == textContent.segments[0].text)
    }

    @Test("keeps CRLF PDF line breaks inside a sentence")
    func keepsCRLFSentenceTogether() throws {
        let content = makeTextContent("A sentence split across\r\nlines remains whole.")

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "A sentence split across\r\nlines remains whole.",
        ])
    }

    @Test("splits text content into paragraphs, not sentences")
    func splitsParagraphsNotSentences() throws {
        let content = makeTextContent(
            "First sentence. Second sentence.\n\nThird sentence. Fourth sentence."
        )

        let tokenized = try CustomTTSTokenizer.tokenize(defaultLanguage: Language("en"))(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "First sentence. Second sentence.",
            "Third sentence. Fourth sentence.",
        ])
    }

    @Test("keeps a locator highlight and surrounding context for every paragraph")
    func preservesLocatorContext() throws {
        let content = makeTextContent(
            "Before paragraph.\n\nThe paragraph being spoken.\n\nAfter paragraph."
        )

        let tokenized = try CustomTTSTokenizer.tokenize(defaultLanguage: Language("en"))(content)
        let textContent = try #require(tokenized.first as? TextContentElement)
        let spoken = try #require(textContent.segments[safe: 1])

        #expect(spoken.text == "The paragraph being spoken.")
        #expect(spoken.locator.text.highlight == spoken.text)
        #expect(spoken.locator.text.before?.contains("Before paragraph.") == true)
        #expect(spoken.locator.text.after?.contains("After paragraph.") == true)
    }

    private func makeTextContent(_ text: String) -> TextContentElement {
        let locator = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml
        )
        return TextContentElement(
            locator: locator,
            role: .body,
            segments: [
                TextContentElement.Segment(locator: locator, text: text),
            ]
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
