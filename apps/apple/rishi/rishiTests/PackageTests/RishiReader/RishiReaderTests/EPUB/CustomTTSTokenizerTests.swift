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

    @Test("EPUB context disambiguates repeated highlights and advances Unicode preceding text")
    func epubContextAndUnicode() throws {
        let content = makeTextContent("Selected first. Café 👩🏽‍🚀 before. Selected second.")
        let trimmed = try #require(CustomTTSTokenizer.trimming(
            content, before: Locator.Text(before: "Café 👩🏽‍🚀 before. ", highlight: "Selected")
        ) as? TextContentElement)
        #expect(trimmed.text == "Selected second.")
        let interior = makeTextContent("Earlier. Prefix. Target.")
        #expect((CustomTTSTokenizer.trimming(interior, before: .init(before: "Prefix. ", highlight: "Target")) as? TextContentElement)?.text == "Target.")
        #expect((CustomTTSTokenizer.trimming(interior, before: .init(highlight: "Target")) as? TextContentElement)?.text == "Target.")
        #expect(CustomTTSTokenizer.trimming(interior, before: .init(highlight: "Missing")) == nil)
        #expect(CustomTTSTokenizer.trimming(interior, before: .init(highlight: "")) == nil)
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

    @Test("PDF paragraph boundaries survive sentence packing and carry canonical offsets")
    func pdfParagraphBoundariesAndMetadata() throws {
        let text = "One short paragraph.\nTwo short paragraph."
        let content = makePDFTextContent(text)
        let tokenizer = CustomTTSTokenizer.tokenizePDF(
            defaultLanguage: Language("en"),
            paragraphRanges: { _, _ in .available([0..<21, 22..<text.utf16.count]) }
        )

        let tokenized = try tokenizer(content)
        let output = try #require(tokenized.first as? TextContentElement)

        #expect(output.segments.map(\.text) == ["One short paragraph.", "Two short paragraph."])
        #expect(output.segments.map { $0.locator.locations.otherLocations["rishiParagraphStartUTF16"]?.integer } == [0, 22])
        #expect(output.segments.map { $0.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer } == [0, 1])
    }

    @Test("packed PDF utterances preserve constituent source and output spans")
    func packedPDFUtteranceCarriesSourceOutputSpans() throws {
        let text = "First sentence.   Second sentence."
        let content = makePDFTextContent(text)
        let tokenized = try CustomTTSTokenizer.tokenizePDF(
            defaultLanguage: Language("en"),
            paragraphRanges: { _, _ in .available([0..<text.utf16.count]) }
        )(content)
        let output = try #require(tokenized.first as? TextContentElement)
        let spans = try #require(output.segments.first?.locator.locations.otherLocations["rishiSourceOutputSpans"]?.array)

        #expect(spans.count == 2)
        #expect(spans[0].object?["sourceStartUTF16"]?.integer == 0)
        #expect(spans[0].object?["sourceEndUTF16"]?.integer == 15)
        #expect(spans[1].object?["sourceStartUTF16"]?.integer == 18)
        #expect(spans[1].object?["outputStartUTF16"]?.integer == 16)
    }

    @Test("PDF start offset trims inside a canonical utterance without renumbering")
    func pdfCursorTrimsCanonicalUtterance() throws {
        let text = "First sentence. Second sentence. Third sentence."
        let content = makePDFTextContent(text)
        let cursor = CustomTTSTokenizer.PDFNarrationTokenizationCursor(targetPage: 1, startUTF16Offset: 16)
        let tokenized = try CustomTTSTokenizer.tokenizePDF(
            defaultLanguage: Language("en"),
            paragraphRanges: { _, _ in .available([0..<text.utf16.count]) },
            cursor: cursor
        )(content)
        let output = try #require(tokenized.first as? TextContentElement)

        #expect(output.segments.map(\.text) == ["Second sentence. Third sentence."])
        #expect(output.segments.first?.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer == 0)
        #expect(cursor.consume(forPage: 1) == nil)
    }

    @Test("long PDF paragraphs split at capacity while keeping one paragraph origin")
    func longPDFParagraphKeepsOneOriginAcrossChunks() throws {
        let first = String(repeating: "a", count: 200) + "."
        let second = String(repeating: "b", count: 200) + "."
        let text = "\(first) \(second)"
        let output = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, _ in .available([0..<text.utf16.count]) }
            )(makePDFTextContent(text)).first as? TextContentElement
        )

        #expect(output.segments.count == 2)
        #expect(output.segments.map { $0.locator.locations.otherLocations["rishiParagraphStartUTF16"]?.integer } == [0, 0])
        #expect(output.segments.map { $0.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer } == [0, 1])
    }

    @Test("paragraph cursor resumes at that paragraph and drops earlier utterances")
    func paragraphCursorDropsEarlierParagraphs() throws {
        let text = "One short paragraph.\nTwo short paragraph."
        let cursor = CustomTTSTokenizer.PDFNarrationTokenizationCursor(
            targetPage: 1,
            paragraphStartUTF16: 22
        )
        let output = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, _ in .available([0..<21, 22..<text.utf16.count]) },
                cursor: cursor
            )(makePDFTextContent(text)).first as? TextContentElement
        )

        #expect(output.segments.map(\.text) == ["Two short paragraph."])
        #expect(output.segments.first?.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer == 1)
    }

    @Test("paragraph Repeat starts at its first utterance and continues through later paragraphs")
    func paragraphRepeatContinuesThroughPageRemainder() throws {
        let first = String(repeating: "a", count: 200) + "."
        let second = String(repeating: "b", count: 200) + "."
        let nextParagraph = "Next paragraph."
        let text = "\(first) \(second)\n\(nextParagraph)"
        let cursor = CustomTTSTokenizer.PDFNarrationTokenizationCursor(
            targetPage: 1,
            paragraphStartUTF16: 0
        )
        let output = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, _ in
                    .available([0..<(first.utf16.count + 1 + second.utf16.count), (first.utf16.count + second.utf16.count + 2)..<text.utf16.count])
                },
                cursor: cursor
            )(makePDFTextContent(text)).first as? TextContentElement
        )

        #expect(output.segments.map(\.text) == [first, second, nextParagraph])
        #expect(output.segments.map { $0.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer } == [0, 1, 2])
    }

    @Test("selection context resolves a repeated highlight using its before text")
    func selectionContextDisambiguatesRepeatedText() throws {
        let text = "Repeated phrase. Middle passage. Repeated phrase."
        let output = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, _ in .available([0..<text.utf16.count]) },
                selectionText: Locator.Text(before: "Middle passage. ", highlight: "Repeated phrase.")
            )(makePDFTextContent(text)).first as? TextContentElement
        )

        #expect(output.segments.map(\.text) == ["Repeated phrase."])
        #expect(output.segments.first?.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer == 0)
    }

    @Test("native selection offset disambiguates repeated highlight without before context")
    func nativeSelectionOffsetDisambiguatesRepeatedText() throws {
        let first = "Repeated phrase."
        let middle = "Middle passage."
        let selected = "Repeated phrase."
        let last = "Final sentence."
        let text = "\(first)\n\(middle)\n\(selected)\n\(last)"
        let selectedOffset = first.utf16.count + 1 + middle.utf16.count + 1
        var selectionLocations: [String: JSONValue] = [:]
        selectionLocations["rishiPDFSelectionStartUTF16"] = .integer(selectedOffset)
        let content = makePDFTextContent(text, otherLocations: selectionLocations)
        let output = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, _ in
                    let middleStart = first.utf16.count + 1
                    let selectedStart = middleStart + middle.utf16.count + 1
                    let lastStart = selectedStart + selected.utf16.count + 1
                    return .available([
                        0..<first.utf16.count,
                        middleStart..<(middleStart + middle.utf16.count),
                        selectedStart..<(selectedStart + selected.utf16.count),
                        lastStart..<text.utf16.count,
                    ])
                },
                selectionText: Locator.Text(highlight: "Repeated phrase."),
                selectionStartUTF16Offset: selectedOffset
            )(content).first as? TextContentElement
        )

        #expect(output.segments.map(\.text) == [selected, last])
        #expect(output.segments.first?.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer == 2)
    }

    @Test("ambiguous selection context yields no page-start utterances")
    func ambiguousSelectionDoesNotReplayPageStart() throws {
        let text = "Repeated phrase. Middle passage. Repeated phrase."
        let page1 = makePDFTextContent(text, page: 1)
        let page2Text = "Page two is not ambiguous."
        let page2 = makePDFTextContent(page2Text, page: 2)
        let tokenizer = CustomTTSTokenizer.tokenizePDF(
            defaultLanguage: Language("en"),
            paragraphRanges: { _, pageText in .available([0..<pageText.utf16.count]) },
            selectionText: Locator.Text(highlight: "Repeated phrase.")
        )
        let firstPage = try tokenizer(page1)
        let secondPage = try tokenizer(page2)

        #expect(firstPage.isEmpty)
        #expect((secondPage.first as? TextContentElement)?.segments.map(\.text) == [page2Text])
    }

    @Test("initial selection applies only to its original page")
    func selectionDoesNotSuppressFollowingPDFPages() throws {
        let page1Text = "Before. Selected passage starts here."
        let page1 = makePDFTextContent(page1Text, page: 1)
        let page2 = makePDFTextContent("Following page must still speak.", page: 2)
        let selectionGate = CustomTTSTokenizer.PDFNarrationSelectionGate(startingPage: 1)
        let tokenizerFactory: (Language?) -> ContentTokenizer = { language in
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: language,
                paragraphRanges: { _, text in .available([0..<text.utf16.count]) },
                selectionText: Locator.Text(before: "Before. ", highlight: "Selected passage"),
                selectionStartUTF16Offset: "Before. ".utf16.count,
                selectionGate: selectionGate
            )
        }

        let firstPage = try tokenizerFactory(Language("en"))(page1)
        let secondPage = try tokenizerFactory(Language("en"))(page2)
        let retriedStartPage = try tokenizerFactory(Language("en"))(page1)

        #expect((firstPage.first as? TextContentElement)?.segments.map(\.text) == ["Selected passage starts here."])
        #expect((secondPage.first as? TextContentElement)?.segments.map(\.text) == ["Following page must still speak."])
        #expect((retriedStartPage.first as? TextContentElement)?.segments.map(\.text) == [page1Text])
    }

    @Test("inherited selection offset is cleared before page two speech and fresh selection")
    func inheritedSelectionOffsetDoesNotLeakIntoLaterPage() throws {
        let selectionOffset = 0
        let inheritedMetadata = [CustomTTSTokenizer.PDFLocatorMetadata.selectionStartUTF16: JSONValue.integer(selectionOffset)]
        let firstPage = makePDFTextContent("Intro. Start passage.", page: 1, otherLocations: inheritedMetadata)
        let secondText = "Repeated phrase.\nMiddle passage.\nRepeated phrase.\nFinal sentence."
        let secondPage = makePDFTextContent(secondText, page: 2, otherLocations: inheritedMetadata)
        let firstPageGate = CustomTTSTokenizer.PDFNarrationSelectionGate(startingPage: 1)
        let firstPassFactory: (Language?) -> ContentTokenizer = { language in
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: language,
                paragraphRanges: { _, text in .available([0..<text.utf16.count]) },
                selectionText: Locator.Text(before: "Intro. ", highlight: "Start passage"),
                selectionGate: firstPageGate
            )
        }

        _ = try firstPassFactory(Language("en"))(firstPage)
        let pageTwoOutput = try #require(firstPassFactory(Language("en"))(secondPage).first as? TextContentElement)
        #expect(pageTwoOutput.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.selectionStartUTF16] == nil)
        #expect(pageTwoOutput.segments.allSatisfy {
            $0.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.selectionStartUTF16] == nil
        })

        let rawPageTwoAfterFirstPass = makePDFTextContent(
            secondText,
            page: 2,
            otherLocations: pageTwoOutput.locator.locations.otherLocations
        )
        let freshStart = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, text in
                    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
                    var start = 0
                    return .available(parts.map { part in
                        defer { start += part.utf16.count + 1 }
                        return start..<(start + part.utf16.count)
                    })
                },
                selectionText: Locator.Text(before: "Repeated phrase.\nMiddle passage.\n", highlight: "Repeated phrase."),
                selectionGate: CustomTTSTokenizer.PDFNarrationSelectionGate(startingPage: 2)
            )(rawPageTwoAfterFirstPass).first as? TextContentElement
        )

        #expect(freshStart.segments.map(\.text) == ["Repeated phrase.", "Final sentence."])
        #expect(freshStart.segments.first?.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal]?.integer == 2)
    }

    @Test("unavailable map clears inherited PDF narration metadata")
    func unavailablePageClearsPriorPageNarrationTags() throws {
        let inherited: [String: JSONValue] = [
            "rishiParagraphStartUTF16": .integer(88),
            "rishiUtteranceOrdinal": .integer(9),
            "rishiSourceOutputSpans": .array([.object(["sourceStartUTF16": .integer(88)])]),
        ]
        let content = makePDFTextContent("New page. ", page: 2, otherLocations: inherited)
        let tokenized = try CustomTTSTokenizer.tokenizePDF(
            defaultLanguage: Language("en"),
            paragraphRanges: { _, _ in .unavailable }
        )(content)
        let output = try #require(tokenized.first as? TextContentElement)
        let locations = try #require(output.segments.first?.locator.locations.otherLocations)

        #expect(output.locator.locations.otherLocations["rishiParagraphStartUTF16"] == nil)
        #expect(output.locator.locations.otherLocations["rishiUtteranceOrdinal"] == nil)
        #expect(output.locator.locations.otherLocations["rishiSourceOutputSpans"] == nil)
        #expect(locations["rishiParagraphStartUTF16"] == nil)
        #expect(locations["rishiUtteranceOrdinal"]?.integer == 0)
        #expect(locations["rishiSourceOutputSpans"]?.array?.first?.object?["sourceStartUTF16"]?.integer == 0)
    }

    @Test("unavailable paragraph maps keep speech safe without claiming a restart origin")
    func unavailablePDFParagraphMapOmitsParagraphOrigin() throws {
        let text = "First sentence. Second sentence."
        let output = try #require(
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: Language("en"),
                paragraphRanges: { _, _ in .unavailable }
            )(makePDFTextContent(text)).first as? TextContentElement
        )

        #expect(output.segments.map(\.text) == ["First sentence. Second sentence."])
        #expect(output.segments.first?.locator.locations.otherLocations["rishiParagraphStartUTF16"] == nil)
        #expect(output.segments.first?.locator.locations.otherLocations["rishiUtteranceOrdinal"]?.integer == 0)
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

    private func makePDFTextContent(
        _ text: String,
        page: Int = 1,
        otherLocations: [String: JSONValue] = [:]
    ) -> TextContentElement {
        let locator = Locator(
            href: AnyURL(string: "document.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(
                fragments: ["page=\(page)"],
                otherLocations: otherLocations
            )
        )
        return TextContentElement(
            locator: locator,
            role: .body,
            segments: [TextContentElement.Segment(locator: locator, text: text)]
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
