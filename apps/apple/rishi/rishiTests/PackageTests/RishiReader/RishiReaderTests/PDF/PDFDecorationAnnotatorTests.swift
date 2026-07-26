@testable import rishi
#if canImport(UIKit)
import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import ReadiumShared
import ReadiumNavigator



@Suite("PDFDecorationAnnotator", .serialized)
struct PDFDecorationAnnotatorTests {

    private func makeLocator(
        page: Int,
        rects: [CGRect]
    ) -> Locator {
        let base = Locator(
            href: RelativeURL(path: "publication.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=\(page)"]),
            text: Locator.Text(highlight: "selected")
        )
        return LocatorHighlightGeometry.attaching(rects: rects, to: base)
    }

    @Test("Plans one annotation spec per rect with 0-based page index")
    func plansOneSpecPerRect() {
        let rects = [
            CGRect(x: 50, y: 100, width: 200, height: 14),
            CGRect(x: 50, y: 80, width: 180, height: 14),
        ]
        let decoration = Decoration(
            id: "hl-1",
            locator: makeLocator(page: 3, rects: rects),
            style: .highlight(tint: UIColor.systemYellow, isActive: false)
        )

        let specs = PDFDecorationAnnotator.specs(
            from: [decoration],
            in: "rishi-highlights"
        )

        #expect(specs.count == 2)
        #expect(specs[0].pageIndex == 2) // page=3 → PDFKit 0-based
        #expect(specs[0].bounds == rects[0])
        #expect(specs[0].decorationId == "hl-1")
        #expect(specs[0].group == "rishi-highlights")
        #expect(specs[1].pageIndex == 2)
        #expect(specs[1].bounds == rects[1])
        #expect(specs[1].decorationId == "hl-1")
    }

    @Test("Uses style tint at pageOverlayOpacity")
    func usesTintAtPageOverlayOpacity() {
        let tint = UIColor.systemPink
        let decoration = Decoration(
            id: "pink",
            locator: makeLocator(page: 1, rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]),
            style: .highlight(tint: tint, isActive: false)
        )

        let specs = PDFDecorationAnnotator.specs(from: [decoration], in: "g")
        #expect(specs.count == 1)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        specs[0].color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(a - HighlightColor.yellow.pageOverlayOpacity) < 0.001)

        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        tint.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
        #expect(abs(r - er) < 0.001)
        #expect(abs(g - eg) < 0.001)
        #expect(abs(b - eb) < 0.001)
    }

    @Test("Treats underline style like highlight")
    func underlineProducesSpecs() {
        let decoration = Decoration(
            id: "u1",
            locator: makeLocator(page: 2, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)]),
            style: .underline(tint: UIColor.systemBlue, isActive: false)
        )
        let specs = PDFDecorationAnnotator.specs(from: [decoration], in: "tts")
        #expect(specs.count == 1)
        #expect(specs[0].decorationId == "u1")
        #expect(specs[0].pageIndex == 1)
    }

    @Test("Skips decorations missing page or rects")
    func skipsIncompleteLocators() {
        let noPage = Locator(
            href: RelativeURL(path: "publication.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: []),
            text: Locator.Text(highlight: "x")
        )
        let withRectsNoPage = LocatorHighlightGeometry.attaching(
            rects: [CGRect(x: 0, y: 0, width: 1, height: 1)],
            to: noPage
        )
        let pageOnly = makeLocator(page: 1, rects: []) // empty rects → no specs
        // Missing rects key entirely
        let pageNoRects = Locator(
            href: RelativeURL(path: "publication.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=1"]),
            text: Locator.Text(highlight: "y")
        )

        let decorations = [
            Decoration(id: "a", locator: withRectsNoPage, style: .highlight()),
            Decoration(id: "b", locator: pageOnly, style: .highlight()),
            Decoration(id: "c", locator: pageNoRects, style: .highlight()),
        ]
        let specs = PDFDecorationAnnotator.specs(from: decorations, in: "g")
        #expect(specs.isEmpty)
    }

    @Test("UserInfo keys identify group and decoration id")
    func userInfoKeys() {
        #expect(PDFDecorationAnnotator.groupUserInfoKey == "rishiDecorationGroup")
        #expect(PDFDecorationAnnotator.idUserInfoKey == "rishiDecorationId")
    }

    @Test("Quad points for bounds are Z-pattern relative to origin (PDF y-up)")
    func quadPointsForBoundsAreZPattern() {
        let bounds = CGRect(x: 50, y: 100, width: 200, height: 14)
        let quads = PDFDecorationAnnotator.quadrilateralPoints(for: bounds)

        #expect(quads.count == 4)
        #expect(quads[0].cgPointValue == CGPoint(x: 0, y: bounds.height))           // UL
        #expect(quads[1].cgPointValue == CGPoint(x: bounds.width, y: bounds.height)) // UR
        #expect(quads[2].cgPointValue == CGPoint(x: 0, y: 0))                        // LL
        #expect(quads[3].cgPointValue == CGPoint(x: bounds.width, y: 0))             // LR
    }
}

@Suite("PDFDecorableNavigator", .serialized)
@MainActor
struct PDFDecorableNavigatorTests {

    typealias KitPDFDocument = PDFKit.PDFDocument

    private func makeLocator(page: Int, rects: [CGRect]) -> Locator {
        let base = Locator(
            href: RelativeURL(path: "publication.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=\(page)"]),
            text: Locator.Text(highlight: "selected")
        )
        return LocatorHighlightGeometry.attaching(rects: rects, to: base)
    }

    private func makePDFDocument(pageCount: Int = 3) throws -> KitPDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { ctx in
            for i in 0..<pageCount {
                ctx.beginPage()
                ("Page \(i + 1)" as NSString).draw(
                    at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                )
            }
        }
        let document = KitPDFDocument(data: data)
        return try #require(document)
    }

    /// Hosts `pdfView` in a container so attach installs the overlay as a
    /// sibling (production Readium hierarchy), not a PDFView child.
    private func hostedPDFView(frame: CGRect = CGRect(x: 0, y: 0, width: 300, height: 400)) -> (container: UIView, pdfView: PDFView) {
        let container = UIView(frame: frame)
        let pdfView = PDFView(frame: container.bounds)
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(pdfView)
        return (container, pdfView)
    }

    @Test("supports highlight and underline styles")
    func supportsHighlightAndUnderline() {
        let nav = PDFDecorableNavigator()
        #expect(nav.supports(decorationStyle: .highlight))
        #expect(nav.supports(decorationStyle: .underline))
        #expect(!nav.supports(decorationStyle: Decoration.Style.Id(rawValue: "unknown")))
    }

    @Test("apply with nil document stashes pending without clearing overlay")
    func applyNilDocumentKeepsPendingAlive() throws {
        let document = try makePDFDocument()
        let (_, pdfView) = hostedPDFView(frame: .zero)
        // No document yet — mirrors setupPDFView timing.
        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        let decoration = Decoration(
            id: "pending",
            locator: makeLocator(page: 1, rects: [CGRect(x: 10, y: 20, width: 100, height: 12)]),
            style: .highlight(tint: .systemYellow)
        )
        nav.apply(decorations: [decoration], in: "rishi-highlights")

        // Must not have wiped pending or painted prematurely.
        #expect(nav.overlaySpecsForTesting(in: "rishi-highlights").isEmpty)

        pdfView.document = document
        nav.reapplyIfNeeded()

        let specs = nav.overlaySpecsForTesting(in: "rishi-highlights")
        #expect(specs.count == 1)
        #expect(specs[0].decorationId == "pending")
    }

    @Test("apply with document pushes specs onto overlay")
    func applyPushesSpecsOntoOverlay() throws {
        let document = try makePDFDocument()
        let (container, pdfView) = hostedPDFView()
        pdfView.document = document

        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        let decoration = Decoration(
            id: "a",
            locator: makeLocator(page: 1, rects: [
                CGRect(x: 10, y: 20, width: 100, height: 12),
                CGRect(x: 10, y: 40, width: 80, height: 12),
            ]),
            style: .highlight(tint: .systemYellow)
        )
        nav.apply(decorations: [decoration], in: "rishi-highlights")

        let specs = nav.overlaySpecsForTesting(in: "rishi-highlights")
        #expect(specs.count == 2)
        #expect(specs.allSatisfy { $0.decorationId == "a" })
        #expect(nav.decorationOverlayView != nil)
        #expect(nav.decorationOverlayView?.superview === container)
    }

    /// Readium `usePageViewController` stacks page content above PDFView
    /// subviews. Overlay must be a sibling above pdfView or highlights
    /// draw but stay invisible.
    @Test("installs overlay as sibling above pdfView, not as a child")
    func installsOverlayAsSiblingAbovePDFView() throws {
        let (container, pdfView) = hostedPDFView()
        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        let overlay = try #require(nav.decorationOverlayView)
        #expect(overlay.superview === container)
        #expect(overlay.superview !== pdfView)
        #expect(container.subviews.last === overlay)
        let pdfIndex = try #require(container.subviews.firstIndex(of: pdfView))
        let overlayIndex = try #require(container.subviews.firstIndex(of: overlay))
        #expect(overlayIndex > pdfIndex)
    }

    @Test("falls back to pdfView child when pdfView has no superview")
    func fallsBackToChildWhenUnhosted() {
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        #expect(nav.decorationOverlayView?.superview === pdfView)
    }

    @Test("apply replaces prior overlay specs in the same group")
    func applyReplacesGroupOverlaySpecs() throws {
        let document = try makePDFDocument()
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        pdfView.document = document

        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        let first = Decoration(
            id: "a",
            locator: makeLocator(page: 1, rects: [CGRect(x: 10, y: 20, width: 100, height: 12)]),
            style: .highlight(tint: .systemYellow)
        )
        nav.apply(decorations: [first], in: "rishi-highlights")
        #expect(nav.overlaySpecsForTesting(in: "rishi-highlights").count == 1)

        let second = Decoration(
            id: "b",
            locator: makeLocator(page: 1, rects: [
                CGRect(x: 10, y: 20, width: 50, height: 12),
                CGRect(x: 10, y: 40, width: 60, height: 12),
            ]),
            style: .highlight(tint: .systemGreen)
        )
        nav.apply(decorations: [second], in: "rishi-highlights")

        let specs = nav.overlaySpecsForTesting(in: "rishi-highlights")
        #expect(specs.count == 2)
        #expect(specs.allSatisfy { $0.decorationId == "b" })
    }

    @Test("apply clears group when decorations empty")
    func applyEmptyClearsGroup() throws {
        let document = try makePDFDocument()
        let pdfView = PDFView(frame: .zero)
        pdfView.document = document
        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        nav.apply(
            decorations: [
                Decoration(
                    id: "a",
                    locator: makeLocator(page: 2, rects: [CGRect(x: 1, y: 1, width: 10, height: 10)]),
                    style: .highlight(tint: .systemBlue)
                )
            ],
            in: "tts"
        )
        #expect(nav.overlaySpecsForTesting(in: "tts").count == 1)

        nav.apply(decorations: [], in: "tts")
        #expect(nav.overlaySpecsForTesting(in: "tts").isEmpty)
    }

    @Test("separate groups do not clobber each other")
    func groupsAreIndependent() throws {
        let document = try makePDFDocument()
        let pdfView = PDFView(frame: .zero)
        pdfView.document = document
        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        nav.apply(
            decorations: [
                Decoration(
                    id: "h1",
                    locator: makeLocator(page: 1, rects: [CGRect(x: 0, y: 0, width: 20, height: 10)]),
                    style: .highlight(tint: .systemYellow)
                )
            ],
            in: "rishi-highlights"
        )
        nav.apply(
            decorations: [
                Decoration(
                    id: "t1",
                    locator: makeLocator(page: 1, rects: [CGRect(x: 0, y: 20, width: 20, height: 10)]),
                    style: .highlight(tint: .systemOrange)
                )
            ],
            in: "rishi-tts"
        )

        #expect(nav.overlaySpecsForTesting(in: "rishi-highlights").count == 1)
        #expect(nav.overlaySpecsForTesting(in: "rishi-tts").count == 1)

        nav.apply(decorations: [], in: "rishi-tts")
        #expect(nav.overlaySpecsForTesting(in: "rishi-highlights").count == 1)
        #expect(nav.overlaySpecsForTesting(in: "rishi-tts").isEmpty)
    }

    @Test("observeDecorationInteractions stores callback without crashing")
    func observeStoresCallback() {
        let nav = PDFDecorableNavigator()
        var activated = false
        nav.observeDecorationInteractions(inGroup: "rishi-highlights") { _ in
            activated = true
        }
        // API must exist; tap delivery is a stub for now.
        #expect(activated == false)
        #expect(nav.hasDecorationInteractionObserver(inGroup: "rishi-highlights"))
    }

    /// Race: Readium calls `setupPDFView` before assigning `pdfView.document`.
    /// Apply must stash decorations and paint them once the document exists
    /// (via ``reapplyIfNeeded`` or ``.PDFViewDocumentChanged``).
    @Test("reapplies stashed decorations once document becomes available")
    func reappliesStashedWhenDocumentReady() throws {
        let document = try makePDFDocument()
        let pdfView = PDFView(frame: .zero)
        // Intentionally no document — mirrors setupPDFView timing.

        let nav = PDFDecorableNavigator()
        nav.attach(pdfView: pdfView)

        let decoration = Decoration(
            id: "late",
            locator: makeLocator(page: 1, rects: [CGRect(x: 10, y: 20, width: 100, height: 12)]),
            style: .highlight(tint: .systemYellow)
        )
        nav.apply(decorations: [decoration], in: "rishi-highlights")
        #expect(nav.overlaySpecsForTesting(in: "rishi-highlights").isEmpty)

        // Document assigned later (as in PDFNavigator.go). The attached
        // `.PDFViewDocumentChanged` observer (or an explicit reapply) paints.
        pdfView.document = document
        nav.reapplyIfNeeded()

        let specs = nav.overlaySpecsForTesting(in: "rishi-highlights")
        #expect(specs.count == 1)
        #expect(specs[0].decorationId == "late")
    }

    @Test("attach with document ready paints previously stashed decorations")
    func attachPaintsStashedDecorations() throws {
        let document = try makePDFDocument()
        let nav = PDFDecorableNavigator()

        nav.apply(
            decorations: [
                Decoration(
                    id: "pre",
                    locator: makeLocator(page: 1, rects: [CGRect(x: 5, y: 5, width: 40, height: 10)]),
                    style: .highlight(tint: .systemGreen)
                )
            ],
            in: "rishi-highlights"
        )

        let pdfView = PDFView(frame: .zero)
        pdfView.document = document
        nav.attach(pdfView: pdfView)

        #expect(nav.overlaySpecsForTesting(in: "rishi-highlights").count == 1)
    }
}
#endif
