import Foundation

/// One node in a PDF Table-of-Contents tree. Pure value type — safe to
/// hand to SwiftUI without any `@MainActor` plumbing.
public struct PDFOutlineNode: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    /// 0-based page index. `nil` if the outline entry has no destination
    /// (rare — e.g. group headers in some manuals).
    public let pageIndex: Int?
    public let children: [PDFOutlineNode]

    public init(
        id: UUID = UUID(),
        label: String,
        pageIndex: Int?,
        children: [PDFOutlineNode] = []
    ) {
        self.id = id
        self.label = label
        self.pageIndex = pageIndex
        self.children = children
    }

    /// Pre-order flat traversal used by accessibility tests and "first leaf"
    /// resolution (e.g. tap a group header → first sub-chapter).
    public func flattened() -> [PDFOutlineNode] {
        [self] + children.flatMap { $0.flattened() }
    }
}
