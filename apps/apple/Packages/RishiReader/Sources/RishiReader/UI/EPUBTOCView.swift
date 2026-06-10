import SwiftUI
import ReadiumShared
import RishiUIKit

/// Modal sheet showing the EPUB's table of contents.
///
/// Tapping an entry calls `onSelect` with the Readium `Link`; the parent
/// (``EPUBReaderScreen``) calls `coordinator.go(to: link)` and dismisses
/// the sheet. Empty-TOC publications get a friendly empty state instead
/// of an empty list.
///
/// Mirrors the shape of Phase 5's ``PDFTOCView`` — kept as a sibling
/// (not generic) so the row payload is the strongly-typed Readium
/// `Link`, not an erased outline-node protocol.
public struct EPUBTOCView: View {

    public let entries: [ReadiumShared.Link]
    public let onSelect: (ReadiumShared.Link) -> Void
    public let onClose: () -> Void

    public init(
        entries: [ReadiumShared.Link],
        onSelect: @escaping (ReadiumShared.Link) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.entries = entries
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Table of Contents",
                        systemImage: "list.bullet.indent",
                        description: Text("This book doesn't include a table of contents.")
                    )
                } else {
                    List(entries, id: \.href) { link in
                        Button {
                            onSelect(link)
                        } label: {
                            VStack(alignment: .leading, spacing: RishiSpacing.xs) {
                                Text(link.title ?? link.href)
                                    .font(RishiTypography.body)
                                    .foregroundStyle(RishiColor.textPrimary)
                                Text(link.href)
                                    .font(RishiTypography.caption)
                                    .foregroundStyle(RishiColor.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
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
}

#Preview("Populated") {
    EPUBTOCView(
        entries: [
            ReadiumShared.Link(href: "OEBPS/chapter01.xhtml", title: "Down the Rabbit-Hole"),
            ReadiumShared.Link(href: "OEBPS/chapter02.xhtml", title: "The Pool of Tears"),
            ReadiumShared.Link(href: "OEBPS/chapter03.xhtml", title: "A Caucus-Race and a Long Tale"),
            ReadiumShared.Link(href: "OEBPS/chapter04.xhtml", title: "The Rabbit Sends in a Little Bill"),
            ReadiumShared.Link(href: "OEBPS/chapter05.xhtml", title: "Advice from a Caterpillar"),
            ReadiumShared.Link(href: "OEBPS/chapter06.xhtml", title: "Pig and Pepper")
        ],
        onSelect: { _ in },
        onClose: {}
    )
}

#Preview("Empty") {
    EPUBTOCView(
        entries: [],
        onSelect: { _ in },
        onClose: {}
    )
}
