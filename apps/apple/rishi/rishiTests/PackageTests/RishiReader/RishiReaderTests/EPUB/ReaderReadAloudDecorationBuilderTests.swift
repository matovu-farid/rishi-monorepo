@testable import rishi
#if canImport(UIKit)
import Testing
import Foundation
import ReadiumShared
import ReadiumNavigator


@Suite("ReaderReadAloudDecorationBuilder")
struct ReaderReadAloudDecorationBuilderTests {

    private let href = AnyURL(string: "chapter1.xhtml")!
    private let mediaType = MediaType.xhtml

    @Test("Locator carries the paragraph as text.highlight on the resource href")
    func locatorHighlightsParagraph() {
        let paragraph = "Alice was beginning to get very tired."
        let locator = ReaderReadAloudDecorationBuilder.locator(
            forParagraph: paragraph,
            href: href,
            mediaType: mediaType
        )
        #expect(locator.text.highlight == paragraph)
        #expect(locator.href.string == "chapter1.xhtml")
    }

    @Test("Decoration reuses a stable id in the rishi-tts group")
    func decorationUsesStableID() {
        let decoration = ReaderReadAloudDecorationBuilder.decoration(
            forParagraph: "Down the rabbit hole.",
            href: href,
            mediaType: mediaType
        )
        #expect(decoration.id == ReaderReadAloudDecorationBuilder.decorationID)
        #expect(decoration.locator.text.highlight == "Down the rabbit hole.")
        #expect(ReaderReadAloudDecorationBuilder.groupName == "rishi-tts")
    }
}
#endif
