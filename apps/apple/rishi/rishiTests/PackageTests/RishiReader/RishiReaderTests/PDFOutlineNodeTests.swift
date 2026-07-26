@testable import rishi
import Testing
import Foundation


@Suite("PDFOutlineNode")
struct PDFOutlineNodeTests {

    @Test("Flattened pre-order traversal")
    func flattenedTraversal() {
        let tree = PDFOutlineNode(
            label: "Part 1", pageIndex: 0,
            children: [
                PDFOutlineNode(label: "Ch 1", pageIndex: 1),
                PDFOutlineNode(label: "Ch 2", pageIndex: 5, children: [
                    PDFOutlineNode(label: "Ch 2.1", pageIndex: 6)
                ])
            ]
        )
        let flat = tree.flattened().map(\.label)
        #expect(flat == ["Part 1", "Ch 1", "Ch 2", "Ch 2.1"])
    }

    @Test("Identifiable IDs are unique by default")
    func uniqueIDs() {
        let a = PDFOutlineNode(label: "x", pageIndex: 0)
        let b = PDFOutlineNode(label: "x", pageIndex: 0)
        #expect(a.id != b.id)
    }

    @Test("nil pageIndex preserved for group headers")
    func nilPageIndexPreserved() {
        let group = PDFOutlineNode(label: "Group", pageIndex: nil)
        #expect(group.pageIndex == nil)
    }
}
