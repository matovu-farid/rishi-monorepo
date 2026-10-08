import Foundation
import ReadiumShared
import Testing
@testable import rishi

@Suite("Bounded EPUB narration resume", .serialized)
@MainActor
struct EPUBNarrationResumeTests {
    private func locator(href: String = "chapter.xhtml", selection: Locator.Text = .init()) throws -> Locator {
        Locator(href: try #require(RelativeURL(path: href)), mediaType: .xhtml,
                locations: .init(otherLocations: ["cssSelector": .string("#shared-paragraph")]), text: selection)
    }
    private func text(_ text: String, href: String = "chapter.xhtml") throws -> TextContentElement {
        let location = try locator(href: href)
        return TextContentElement(locator: location, role: .body, segments: [.init(locator: location, text: text)])
    }
    private func scan(_ elements: [ContentElement], from location: Locator) async throws -> EPUBNarrationResumePlan? {
        var index = 0
        return try await EPUBNarrationResumePlanner.scan(from: location) {
            guard index < elements.count else { return nil }
            defer { index += 1 }
            return elements[index]
        }
    }
    private func spoken(_ tokens: [ContentElement]) -> String {
        tokens.compactMap { ($0 as? TextContentElement)?.text }.joined()
    }

    @Test("shared-selector chunks and nontext elements count toward a confirmed factory-wide ordinal")
    func sharedSelectorAndFactoryRecreation() async throws {
        let location = try locator(selection: .init(before: "Prefix. ", highlight: "Selected"))
        let image = ImageContentElement(locator: try locator(), embeddedLink: Link(href: "image.png"))
        let elements: [ContentElement] = [try text("Earlier br chunk."), image, try text("Prefix. Selected target passage."), try text("Following chunk.")]
        let plan = try #require(try await scan(elements, from: location))
        #expect(plan.targetOrdinal == 2)
        #expect(plan.selection.before == "Prefix. ")
        #expect(plan.selection.highlight == "Selected")
        let gate = EPUBNarrationSelectionGate(plan: plan, fallbackSelection: location.text)
        // Readium asks the factory for a fresh closure for every element.
        #expect(try gate.tokenizer(defaultLanguage: Language("en"))(elements[0]).isEmpty)
        #expect(try gate.tokenizer(defaultLanguage: Language("en"))(elements[1]).isEmpty)
        #expect(try spoken(gate.tokenizer(defaultLanguage: Language("en"))(elements[2])) == "Selected target passage.")
        #expect(try spoken(gate.tokenizer(defaultLanguage: Language("en"))(elements[3])) == "Following chunk.")
    }

    @Test("preflight skips repeated highlights until preceding context confirms the correct br chunk")
    func repeatedHighlightAcrossChunks() async throws {
        let selection = Locator.Text(before: "Unique previous chunk. ", highlight: "Repeated")
        let location = try locator(selection: selection)
        let earlier = try text("Repeated earlier occurrence.")
        var target = try text("Repeated correct occurrence.")
        target.locator = target.locator.copy(text: { $0.before = "Unique previous chunk. " })
        let plan = try #require(try await scan([earlier, target], from: location))
        #expect(plan.targetOrdinal == 1)
        let gate = EPUBNarrationSelectionGate(plan: plan, fallbackSelection: selection)
        #expect(try gate.tokenizer(defaultLanguage: nil)(earlier).isEmpty)
        #expect(try spoken(gate.tokenizer(defaultLanguage: nil)(target)) == "Repeated correct occurrence.")
    }

    @Test("missing target at final-resource EOF, resource boundary and iterator failure return zero-skip fallback")
    func noMatchFallback() async throws {
        let location = try locator(selection: .init(highlight: "Missing selection"))
        let first = try text("Original containing paragraph.")
        #expect(try await scan([first], from: location) == nil)
        #expect(try await scan([first, text("Missing selection", href: "next.xhtml")], from: location) == nil)
        enum Failure: Error { case iterator }
        #expect(try await EPUBNarrationResumePlanner.scan(from: location, next: { throw Failure.iterator }) == nil)
        let gate = EPUBNarrationSelectionGate(plan: nil, fallbackSelection: location.text)
        #expect(try spoken(gate.tokenizer(defaultLanguage: Language("en"))(first)) == "Original containing paragraph.")
    }

    @Test("both caps include every yielded element and all UTF8 text bytes")
    func caps() async throws {
        let location = try locator(selection: .init(highlight: "Target"))
        let image = ImageContentElement(locator: try locator(), embeddedLink: Link(href: "image.png"))
        var count = 0
        let capped = try await EPUBNarrationResumePlanner.scan(from: location) {
            count += 1
            return count <= 64 ? image : try text("Target")
        }
        #expect(capped == nil)
        #expect(count == 64)
        let huge = try text(String(repeating: "é", count: 131_072) + "Target")
        #expect(try await scan([huge], from: location) == nil)
    }

    @Test("cancellation after an iterator suspension aborts plan installation")
    func cancellation() async throws {
        let location = try locator(selection: .init(highlight: "Target"))
        var continuation: CheckedContinuation<Void, Never>?
        let operation = Task {
            try await EPUBNarrationResumePlanner.scan(from: location) {
                await withCheckedContinuation { continuation = $0 }
                return try text("Target")
            }
        }
        while continuation == nil { await Task.yield() }
        operation.cancel()
        continuation?.resume()
        do { _ = try await operation.value; Issue.record("cancelled scan installed plan") }
        catch is CancellationError {}
    }

    @Test("fallback trims once at the original selection and never skips a later resource")
    func fallbackTrimsOnce() throws {
        let selection = Locator.Text(before: "Intro. ", highlight: "Selected")
        let gate = EPUBNarrationSelectionGate(plan: nil, fallbackSelection: selection)
        #expect(try spoken(gate.tokenizer(defaultLanguage: nil)(text("Intro. Selected content."))) == "Selected content.")
        #expect(try spoken(gate.tokenizer(defaultLanguage: nil)(text("Intro. Selected again.", href: "next.xhtml"))) == "Intro. Selected again.")
    }
}
