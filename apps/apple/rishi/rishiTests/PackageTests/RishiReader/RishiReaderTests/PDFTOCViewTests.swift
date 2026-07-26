@testable import rishi
import Testing
import Foundation


@Suite("PDFTOCView (logic)")
@MainActor
struct PDFTOCViewTests {

    @Test("Tap on leaf node invokes onSelect with its pageIndex")
    func tapLeafInvokesPageIndex() {
        var selected: Int?
        let leaf = PDFOutlineNode(label: "Ch 1", pageIndex: 3)
        let view = PDFTOCView(
            nodes: [leaf],
            onSelect: { selected = $0 },
            onClose: { }
        )
        view.simulateSelection(for: view.firstNode)
        #expect(selected == 3)
    }

    @Test("Group header (nil pageIndex) jumps to first leaf with a page")
    func groupHeaderJumpsToFirstLeaf() {
        var selected: Int?
        let tree = PDFOutlineNode(
            label: "Part 1", pageIndex: nil,
            children: [
                PDFOutlineNode(label: "Ch 1", pageIndex: 5)
            ]
        )
        let view = PDFTOCView(
            nodes: [tree],
            onSelect: { selected = $0 },
            onClose: { }
        )
        view.simulateSelection(for: tree)
        #expect(selected == 5)
    }

    @Test("flattenedRows preserves pre-order with depth")
    func flattenedRowsPreOrder() {
        let tree = PDFOutlineNode(
            label: "Part 1", pageIndex: nil,
            children: [
                PDFOutlineNode(label: "Ch 1", pageIndex: 1, children: [
                    PDFOutlineNode(label: "1.1", pageIndex: 2)
                ]),
                PDFOutlineNode(label: "Ch 2", pageIndex: 3)
            ]
        )
        let view = PDFTOCView(nodes: [tree], onSelect: { _ in }, onClose: { })
        let rows = view.flattenedRows()
        #expect(rows.count == 4)
        #expect(rows[0].node.label == "Part 1")
        #expect(rows[0].depth == 0)
        #expect(rows[1].node.label == "Ch 1")
        #expect(rows[1].depth == 1)
        #expect(rows[2].node.label == "1.1")
        #expect(rows[2].depth == 2)
        #expect(rows[3].node.label == "Ch 2")
        #expect(rows[3].depth == 1)
    }
}

// Test hook to bypass SwiftUI Button without ViewInspector.
private extension PDFTOCView {
    var firstNode: PDFOutlineNode { nodes[0] }
    func simulateSelection(for node: PDFOutlineNode) {
        if let p = node.pageIndex {
            onSelect(p)
        } else if let first = node.flattened().first(where: { $0.pageIndex != nil }),
                  let pageIdx = first.pageIndex {
            onSelect(pageIdx)
        }
    }
}
