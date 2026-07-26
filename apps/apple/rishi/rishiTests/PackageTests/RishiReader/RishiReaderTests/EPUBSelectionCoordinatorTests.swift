@testable import rishi
import Testing
import Foundation
import ReadiumShared


/// Tests for the pure-Swift selection→locator adapter used by the EPUB
/// reader (plan 06-05 Task 1).
///
/// `@Suite(.serialized)` per project convention — these tests don't share
/// mutable state across cases, but the suite-level pattern keeps Swift
/// Testing's parallelism off as a project-wide default for new EPUB suites.
@Suite("EPUBSelectionCoordinator", .serialized)
struct EPUBSelectionCoordinatorTests {

    private func makeLocator(text highlight: String?) -> Locator {
        Locator(
            href: RelativeURL(path: "chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.5),
            text: Locator.Text(highlight: highlight)
        )
    }

    @Test("Empty highlight text returns nil")
    func emptyTextReturnsNil() {
        let locator = makeLocator(text: "")
        #expect(EPUBSelectionCoordinator.makeLocator(fromLocator: locator) == nil)
    }

    @Test("Nil highlight returns nil")
    func nilHighlightReturnsNil() {
        let locator = makeLocator(text: nil)
        #expect(EPUBSelectionCoordinator.makeLocator(fromLocator: locator) == nil)
    }

    @Test("Whitespace-only selection returns nil")
    func whitespaceOnlyReturnsNil() {
        let locator = makeLocator(text: "   \n\t  ")
        #expect(EPUBSelectionCoordinator.makeLocator(fromLocator: locator) == nil)
    }

    @Test("Non-empty selection produces EPUBHighlightLocator with snippet")
    func nonEmptyProducesLocator() throws {
        let locator = makeLocator(text: "Down the rabbit hole")
        let result = try #require(EPUBSelectionCoordinator.makeLocator(fromLocator: locator))
        #expect(result.text == "Down the rabbit hole")
        #expect(!result.readiumLocator.isEmpty)
    }

    @Test("Selection round-trips through EPUBHighlightLocator codec")
    func roundTripsThroughCodec() throws {
        let locator = makeLocator(text: "Curiouser and curiouser")
        let wrapper = try #require(EPUBSelectionCoordinator.makeLocator(fromLocator: locator))
        let json = try wrapper.encodedJSONString()
        let decoded = try EPUBHighlightLocator.decode(jsonString: json)
        #expect(decoded.text == "Curiouser and curiouser")
    }
}
