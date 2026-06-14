#if canImport(UIKit)
import Testing
import Foundation
import ReadiumShared
@testable import RishiReader

@Suite("EPUBReadAloudDecorationBuilder")
struct EPUBReadAloudDecorationBuilderTests {

    private let href = AnyURL(string: "chapter1.xhtml")!
    private let mediaType = MediaType.xhtml

    @Test("Locator carries the paragraph as text.highlight on the resource href")
    func locatorHighlightsParagraph() {
        let paragraph = "Alice was beginning to get very tired."
        let locator = EPUBReadAloudDecorationBuilder.locator(
            forParagraph: paragraph,
            href: href,
            mediaType: mediaType
        )
        #expect(locator.text.highlight == paragraph)
        #expect(locator.href.string == "chapter1.xhtml")
    }

    @Test("Decoration reuses a stable id in the rishi-tts group")
    func decorationUsesStableID() {
        let decoration = EPUBReadAloudDecorationBuilder.decoration(
            forParagraph: "Down the rabbit hole.",
            href: href,
            mediaType: mediaType
        )
        #expect(decoration.id == EPUBReadAloudDecorationBuilder.decorationID)
        #expect(decoration.locator.text.highlight == "Down the rabbit hole.")
        #expect(EPUBReadAloudDecorationBuilder.groupName == "rishi-tts")
    }
}
#endif
