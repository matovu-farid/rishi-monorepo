import SwiftUI


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
        // A plain header Button is used instead of a `NavigationStack` +
        // `.toolbar` "Done": on Mac Catalyst the sheet's NavigationStack
        // bar leaks into the window chrome and its confirmationAction
        // button does not reliably fire/dismiss. A plain button in the
        // view body fires on every platform.
        VStack(spacing: 0) {
            header
            Divider()
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack {
            Text("Contents")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
            Spacer()
            Button("Done", action: onClose)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.accent)
        }
        .padding(.horizontal, RishiSpacing.l)
        .padding(.vertical, RishiSpacing.m)
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

#Preview("Populated outline") {
    PDFTOCView(
        nodes: [
            PDFOutlineNode(
                label: "Part I — Foundations",
                pageIndex: 1,
                children: [
                    PDFOutlineNode(label: "Chapter 1 — Introduction", pageIndex: 3),
                    PDFOutlineNode(
                        label: "Chapter 2 — Concepts",
                        pageIndex: 17,
                        children: [
                            PDFOutlineNode(label: "Definitions", pageIndex: 19),
                            PDFOutlineNode(label: "Examples", pageIndex: 28)
                        ]
                    )
                ]
            ),
            PDFOutlineNode(
                label: "Part II — Practice",
                pageIndex: 55,
                children: [
                    PDFOutlineNode(label: "Chapter 3 — Patterns", pageIndex: 57),
                    PDFOutlineNode(label: "Chapter 4 — Pitfalls", pageIndex: 92)
                ]
            ),
            PDFOutlineNode(label: "Bibliography", pageIndex: 140),
            PDFOutlineNode(label: "Index", pageIndex: 152)
        ],
        onSelect: { _ in },
        onClose: {}
    )
}

#Preview("Empty outline") {
    PDFTOCView(
        nodes: [],
        onSelect: { _ in },
        onClose: {}
    )
}
