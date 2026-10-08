@testable import rishi
import CoreGraphics
import CoreText
import Dispatch
import Foundation
import PDFKit
import ReadiumShared
import Synchronization
import Testing

@Suite("PDF narration target resolver", .serialized)
@MainActor
struct PDFNarrationTargetResolverTests {
    private final class Lifetime {}
    private final class WeakLifetime {
        weak var value: Lifetime?
        init(_ value: Lifetime) { self.value = value }
    }

    /// Gates the real detached map construction, without an alternate content algorithm.
    private final class SourceProbe: BookSourceEffectAdmitting, Sendable {
        private struct State { var closed = false; var calls = 0; var releases = 0 }
        private let state = Mutex(State())
        private let gate = DispatchSemaphore(value: 0)
        private let gatesFirstRead: Bool
        let entered: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation

        init(gatesFirstRead: Bool = false) {
            self.gatesFirstRead = gatesFirstRead
            let stream = AsyncStream<Void>.makeStream()
            entered = stream.stream
            enteredContinuation = stream.continuation
        }

        var counts: (calls: Int, releases: Int) {
            state.withLock { ($0.calls, $0.releases) }
        }

        func admit(_ permit: BookSourceAccessPermit) throws -> SourceEffectAdmission {
            let first = try state.withLock { state in
                guard !state.closed else { throw BookSourceAccessError.revoked }
                state.calls += 1
                return state.calls == 1
            }
            if first && gatesFirstRead {
                enteredContinuation.yield(())
                guard gate.wait(timeout: .now() + 5) == .success else {
                    throw BookSourceAccessError.revoked
                }
            }
            return SourceEffectAdmission { [self] in
                state.withLock { $0.releases += 1 }
            }
        }

        func closeAdmission(_ permit: BookSourceAccessPermit) {
            state.withLock { $0.closed = true }
        }
        func drain(_ permit: BookSourceAccessPermit) async {}
        func resume() { gate.signal() }
    }

    private func writePDF(root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("narration.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        // The normal 16-point leading calibrates the geometry grouper; the
        // larger gap then identifies the final paragraph. Two lines alone
        // make their only gap the median pitch and produce one paragraph.
        let baselines: [CGFloat] = [720, 704, 560]
        for lines in [
            ["Alpha opening paragraph.", "Alpha continuation line.", "Alpha final paragraph."],
            [],
            ["Gamma opening paragraph.", "Gamma continuation line.", "Gamma final paragraph."]
        ] {
            context.beginPDFPage(nil)
            for (index, text) in lines.enumerated() {
                let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let attributed = NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)
                ])
                context.textPosition = CGPoint(x: 72, y: baselines[index])
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func input(
        url: URL,
        lifetime: AnyObject? = nil,
        effects: (any BookSourceEffectAdmitting)? = nil,
        permit: BookSourceAccessPermit? = nil
    ) async throws -> PDFNarrationLookupInput {
        let publication = try await PublicationLoader(unpackedCache: nil).open(fileURL: url)
        let link = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: link.href))
        return PDFNarrationLookupInput(
            publication: publication,
            documentURL: url,
            baseLocator: Locator(href: href, mediaType: .pdf),
            sourceLifetime: lifetime,
            sourceEffects: effects,
            sourceAccessPermit: permit
        )
    }

    private func root() -> URL {
        URL.temporaryDirectory.appendingPathComponent("PDFResolver-\(UUID())", isDirectory: true)
    }

    @Test("adjacent utterances preserve page, ordinal, native paragraph offset and locator")
    func adjacentMetadata() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writePDF(root: root)
        let input = try await input(url: url)
        let target = try #require(await PDFNarrationTargetResolver.resolve(
            input: input, cursor: .init(page: 1, ordinal: 0), delta: 1
        ))
        #expect(target.page == 1)
        #expect(target.ordinal == 1)
        #expect(target.locator.locations.page == 1)
        #expect(target.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal]?.integer == 1)
        #expect(target.locator.text.highlight?.contains("Alpha final paragraph.") == true)
        let document = try #require(PDFDocument(url: url))
        let pageText = try #require(document.page(at: 0)?.string)
        let expectedStart = (pageText as NSString).range(of: "Alpha final paragraph.").location
        #expect(expectedStart != NSNotFound)
        #expect(target.paragraphStart == expectedStart)
        #expect(target.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.paragraphStartUTF16]?.integer == expectedStart)
        let previous = try #require(await PDFNarrationTargetResolver.resolve(
            input: input, cursor: .init(page: 1, ordinal: 1), delta: -1
        ))
        #expect(previous.ordinal == 0)
        #expect(previous.locator.text.highlight?.contains("Alpha opening paragraph.") == true)
    }

    @Test("forward and reverse traversal skip a page without selectable text", arguments: [1, -1])
    func crossesEmptyPage(delta: Int) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await input(url: writePDF(root: root))
        let cursor = PDFNarrationCursor(page: delta > 0 ? 1 : 3, ordinal: delta > 0 ? 1 : 0)
        let target = try #require(await PDFNarrationTargetResolver.resolve(input: input, cursor: cursor, delta: delta))
        #expect(target.page == (delta > 0 ? 3 : 1))
        #expect(target.ordinal == (delta > 0 ? 0 : 1))
        #expect(target.locator.text.highlight?.contains(delta > 0 ? "Gamma opening" : "Alpha final") == true)
    }

    @Test("missing ordinal preserves the existing adjacent-page fallback", arguments: [1, -1])
    func missingOrdinal(delta: Int) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await input(url: writePDF(root: root))
        let target = try #require(await PDFNarrationTargetResolver.resolve(
            input: input, cursor: .init(page: delta > 0 ? 1 : 3, ordinal: 999), delta: delta
        ))
        #expect(target.page == (delta > 0 ? 3 : 1))
        #expect(target.ordinal == (delta > 0 ? 0 : 1))
    }

    @Test("document boundaries return no target", arguments: [1, -1])
    func boundaries(delta: Int) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await input(url: writePDF(root: root))
        let cursor = PDFNarrationCursor(page: delta > 0 ? 3 : 1, ordinal: delta > 0 ? 1 : 0)
        #expect(await PDFNarrationTargetResolver.resolve(input: input, cursor: cursor, delta: delta) == nil)
    }

    @Test("source geometry admits and releases real map reads")
    func sourceAdmissions() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SourceProbe()
        let input = try await input(url: writePDF(root: root), effects: probe, permit: .init())
        let target = await PDFNarrationTargetResolver.resolve(input: input, cursor: .init(page: 1, ordinal: 0), delta: 1)
        #expect(target?.paragraphStart != nil)
        #expect(probe.counts.calls >= 4)
        #expect(probe.counts.calls == probe.counts.releases)
    }

    @Test("revoked geometry retains full-page fallback without fabricated paragraph metadata")
    func revokedGeometryFallback() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SourceProbe()
        let permit = BookSourceAccessPermit()
        probe.closeAdmission(permit)
        let input = try await input(url: writePDF(root: root), effects: probe, permit: permit)
        let target = try #require(await PDFNarrationTargetResolver.resolve(
            input: input, cursor: .init(page: 1, ordinal: 999), delta: 1
        ))
        #expect(target.page == 3)
        #expect(target.locator.text.highlight?.contains("Gamma") == true)
        #expect(target.paragraphStart == nil)
        #expect(target.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.paragraphStartUTF16] == nil)
    }

    private func startLookup(_ input: PDFNarrationLookupInput) -> Task<PDFNarrationTarget?, Never> {
        Task {
            await PDFNarrationTargetResolver.resolve(input: input, cursor: .init(page: 1, ordinal: 0), delta: 1)
        }
    }

    private func gatedLifetime(url: URL) async throws -> WeakLifetime {
        var lifetime: Lifetime? = Lifetime()
        let weakLifetime = WeakLifetime(try #require(lifetime))
        let probe = SourceProbe(gatesFirstRead: true)
        var input: PDFNarrationLookupInput? = try await input(url: url, lifetime: lifetime, effects: probe, permit: .init())
        let task = startLookup(try #require(input))
        lifetime = nil
        input = nil
        for await _ in probe.entered { break }
        #expect(weakLifetime.value != nil)
        probe.resume()
        #expect(await task.value != nil)
        return weakLifetime
    }

    @Test("detached lookup retains the source lifetime through a gated read then releases it")
    func sourceLifetime() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let weakLifetime = try await gatedLifetime(url: writePDF(root: root))
        #expect(weakLifetime.value == nil)
    }
}
