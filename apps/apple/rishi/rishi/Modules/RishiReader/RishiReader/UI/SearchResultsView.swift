import SwiftUI


/// Phase 37 Plan 37-04 — one row in the shared in-book search-results sheet.
///
/// Engine-agnostic: the PDF model maps `PDFSearchResult -> SearchResultRow`
/// and the EPUB model (37-05) maps its Readium locators into the same shape,
/// so both readers present the same ``SearchResultsView`` from the shared
/// `ReaderSheet.search` case. The `id` is carried through from the engine
/// result so the screen can look the live selection/locator back up on select.
public struct SearchResultRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Primary line — e.g. "Page 12" (PDF) or a chapter title (EPUB).
    public let title: String
    /// Secondary line — the matched-text snippet.
    public let subtitle: String

    public init(id: UUID = UUID(), title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// Native in-book search sheet: a plain search `TextField` over a results
/// `List`, shared by the PDF (37-04) and EPUB (37-05) readers.
///
/// Deliberately uses an in-sheet `TextField` rather than a top-level
/// searchable modifier (RESEARCH Pitfall 6): a second top-level search field
/// collides with the library's search field and PDFKit's own Find bar, so the
/// search field is hand-placed inside the sheet — still a native control, just
/// not the modifier form.
///
/// Mirrors ``ReaderTOCView`` / ``BookmarksListView`` plain-header chrome instead
/// of a `NavigationStack` + toolbar "Done": on Mac Catalyst the sheet's
/// NavigationStack bar leaks into the window chrome and its confirmationAction
/// does not reliably dismiss, so a plain header `Button` is used.
public struct SearchResultsView: View {

    @Binding private var query: String
    private let isSearching: Bool
    private let rows: [SearchResultRow]
    private let onSubmit: () -> Void
    private let onSelect: (SearchResultRow) -> Void
    private let onClose: () -> Void

    public init(
        query: Binding<String>,
        isSearching: Bool,
        rows: [SearchResultRow],
        onSubmit: @escaping () -> Void,
        onSelect: @escaping (SearchResultRow) -> Void,
        onClose: @escaping () -> Void
    ) {
        self._query = query
        self.isSearching = isSearching
        self.rows = rows
        self.onSubmit = onSubmit
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack {
            Text("Search")
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

    private var searchField: some View {
        HStack(spacing: RishiSpacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(RishiColor.textSecondary)
            TextField("Search in book", text: $query)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("reader.search.field")
        }
        .padding(.horizontal, RishiSpacing.l)
        .padding(.vertical, RishiSpacing.m)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Type a word or phrase and search to find it in this book.")
            )
        } else {
            List(rows) { row in
                Button {
                    onSelect(row)
                } label: {
                    VStack(alignment: .leading, spacing: RishiSpacing.xs) {
                        Text(row.title)
                            .font(RishiTypography.body)
                            .foregroundStyle(RishiColor.textPrimary)
                        Text(row.subtitle)
                            .font(RishiTypography.caption)
                            .foregroundStyle(RishiColor.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

#Preview("Results") {
    SearchResultsView(
        query: .constant("times"),
        isSearching: false,
        rows: [
            SearchResultRow(title: "Page 3", subtitle: "It was the best of times"),
            SearchResultRow(title: "Page 12", subtitle: "the worst of times, it was the age"),
        ],
        onSubmit: {},
        onSelect: { _ in },
        onClose: {}
    )
}

#Preview("Searching") {
    SearchResultsView(
        query: .constant("times"),
        isSearching: true,
        rows: [],
        onSubmit: {},
        onSelect: { _ in },
        onClose: {}
    )
}

#Preview("Empty") {
    SearchResultsView(
        query: .constant(""),
        isSearching: false,
        rows: [],
        onSubmit: {},
        onSelect: { _ in },
        onClose: {}
    )
}
