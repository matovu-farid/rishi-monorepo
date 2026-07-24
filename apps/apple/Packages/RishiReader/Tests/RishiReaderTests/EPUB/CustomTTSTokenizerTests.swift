import Foundation
import ReadiumShared
import Testing
@testable import RishiReader

@Suite("Custom TTS tokenizer")
struct CustomTTSTokenizerTests {
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

    @Test("supports sentence granularity")
    func splitsSentencesWhenRequested() throws {
        let content = makeTextContent(
            "First sentence. Second sentence."
        )

        let tokenized = try CustomTTSTokenizer.tokenize(
            defaultLanguage: Language("en"),
            granularity: .sentence
        )(content)
        let textContent = try #require(tokenized.first as? TextContentElement)

        #expect(textContent.segments.map(\.text) == [
            "First sentence.",
            "Second sentence.",
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
            "This sentence continues across\nvisual lines without ending.",
            "Next sentence.",
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
