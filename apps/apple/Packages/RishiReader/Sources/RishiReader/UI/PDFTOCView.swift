import SwiftUI
import RishiUIKit

/// Modal sheet showing the PDF's outline. Tapping an entry calls `onSelect`
/// with the destination page index; the parent (PDFReaderScreen) calls
/// `viewModel.seek(toPage:)` and dismisses the sheet.
///
/// Implementation note (Swift 6 / SwiftUI): a `ForEach` cannot return a
/// `Group { row(); ForEach(children) }` whose contents differ shape-by-shape.
/// We flatten the outline tree to a pre-order list of (node, depth) tuples
/// outside the view builder so the `List`/`ForEach` sees a homogeneous row
/// shape. `flattenedRows()` preserves the parent-then-children ordering.
public struct PDFTOCView: View {

    public let nodes: [PDFOutlineNode]
    public let onSelect: (Int) -> Void
    public let onClose: () -> Void

    public init(
        nodes: [PDFOutlineNode],
        onSelect: @escaping (Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.nodes = nodes
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Group {
                if nodes.isEmpty {
                    ContentUnavailableView(
                        "No Table of Contents",
                        systemImage: "list.bullet.indent",
                        description: Text("This PDF doesn't include an outline.")
                    )
                } else {
                    List {
                        ForEach(flattenedRows(), id: \.node.id) { entry in
                            row(for: entry.node, depth: entry.depth)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contents")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(for node: PDFOutlineNode, depth: Int) -> some View {
        Button(action: { handleTap(node: node) }) {
            HStack {
                Text(node.label)
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Spacer()
                if let page = node.pageIndex {
                    Text("\(page + 1)")
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, CGFloat(depth) * RishiSpacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleTap(node: PDFOutlineNode) {
        if let page = node.pageIndex {
            onSelect(page)
        } else if let firstLeaf = node.flattened().first(where: { $0.pageIndex != nil }),
                  let p = firstLeaf.pageIndex {
            onSelect(p)
        }
    }

    // MARK: - Tree flattening

    struct FlatEntry {
        let node: PDFOutlineNode
        let depth: Int
    }

    /// Pre-order flatten with depth tracking. Internal so tests can verify
    /// ordering without poking the SwiftUI body.
    func flattenedRows() -> [FlatEntry] {
        var out: [FlatEntry] = []
        for node in nodes {
            appendFlat(node, depth: 0, into: &out)
        }
        return out
    }

    private func appendFlat(_ node: PDFOutlineNode, depth: Int, into out: inout [FlatEntry]) {
        out.append(FlatEntry(node: node, depth: depth))
        for child in node.children {
            appendFlat(child, depth: depth + 1, into: &out)
        }
    }
}
