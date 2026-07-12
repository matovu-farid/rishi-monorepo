import SwiftUI
import ReadiumShared
import RishiUIKit

/// Modal sheet showing the EPUB's table of contents.
///
/// Tapping an entry calls `onSelect` with the Readium `Link`; the parent
/// (``ReaderScreen``) calls `coordinator.go(to: link)` and dismisses
/// the sheet. Empty-TOC publications get a friendly empty state instead
/// of an empty list.
///
/// Mirrors the shape of Phase 5's ``PDFTOCView`` — kept as a sibling
/// (not generic) so the row payload is the strongly-typed Readium
/// `Link`, not an erased outline-node protocol.
public struct ReaderTOCView: View {

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
        // A plain header Button is used instead of a `NavigationStack` +
        // `.toolbar` "Done": on Mac Catalyst the sheet's NavigationStack
        // bar leaks into the window chrome and its confirmationAction
        // button does not reliably fire/dismiss. A plain button in the
        // view body fires on every platform.
        VStack(spacing: 0) {
            header
            Divider()
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
}

#Preview("Populated") {
    ReaderTOCView(
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
    ReaderTOCView(
        entries: [],
        onSelect: { _ in },
        onClose: {}
    )
}
