import SwiftUI



/// SwiftUI view modifier that attaches `.searchable(...)` to a Library
/// container view. Also renders a `ContentUnavailableView` overlay when a
/// non-empty query produces zero results.
///
/// Usage from Plan 04-06:
/// ```swift
/// NavigationStack { LibraryView(...) }
///     .librarySearchable(
///         text: $vm.searchText,
///         filteredIsEmpty: vm.filteredBooks.isEmpty
///     )
/// ```
struct LibrarySearchable: ViewModifier {

    @Binding public var text: String
    public let filteredIsEmpty: Bool

    public init(text: Binding<String>, filteredIsEmpty: Bool) {
        self._text = text
        self.filteredIsEmpty = filteredIsEmpty
    }

    public func body(content: Content) -> some View {
        searchableContent(content)
            .overlay {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && filteredIsEmpty
                {
                    ContentUnavailableView.search(text: text)
                        .background(RishiColor.background)
                }
            }
    }

    @ViewBuilder
    private func searchableContent(_ content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    CatalystLibrarySearchField(text: $text)
                }
            }
        #else
            content.searchable(
                text: $text,
                placement: searchPlacement,
                prompt: Text("Search title or author")
            )
        #endif
    }

    /// `.toolbar` on Mac Catalyst (sidebar-aware) + macOS host (dev-build),
    /// `.navigationBarDrawer` on iPhone/iPad — both are system-standard
    /// placements per Apple HIG. macOS host coverage exists only so package
    /// `swift build`/`swift test` succeeds on the dev machine; the rishi app
    /// itself ships iOS + Mac Catalyst.
    private var searchPlacement: SearchFieldPlacement {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .toolbar
        #else
        return .navigationBarDrawer(displayMode: .always)
        #endif
    }
}

#if targetEnvironment(macCatalyst)

private struct CatalystLibrarySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search title or author", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .focusEffectDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 320, height: 30)
        .background(Color(uiColor: .systemBackground), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.35),
                    lineWidth: 1
                )
        }
        .contentShape(Capsule())
        .onTapGesture {
            isFocused = true
        }
        .onAppear {
            clearInitialFocus()
        }
        .task {
            // Catalyst may assign first-responder status after the toolbar
            // item appears, so clear it once more on the next run-loop turn.
            await Task.yield()
            clearInitialFocus()
        }
        .accessibilityElement(children: .contain)
    }

    private func clearInitialFocus() {
        isFocused = false
    }
}

#endif

extension View {
    /// Adds the library-shell `.searchable(...)` + empty-results overlay.
    ///
    /// - Parameter text: bound to `LibraryViewModel.searchText`
    ///   (debounced upstream in Plan 04-06).
    /// - Parameter filteredIsEmpty: true when the current `text` filters
    ///   every book away — drives the `ContentUnavailableView.search` overlay.
    func librarySearchable(text: Binding<String>, filteredIsEmpty: Bool) -> some View {
        modifier(LibrarySearchable(text: text, filteredIsEmpty: filteredIsEmpty))
    }
}

private struct LibrarySearchablePreviewHost: View {
    @State var query: String
    let filteredIsEmpty: Bool

    var body: some View {
        NavigationStack {
            List {
                Text("Result A").foregroundStyle(RishiColor.textPrimary)
                Text("Result B").foregroundStyle(RishiColor.textPrimary)
                Text("Result C").foregroundStyle(RishiColor.textPrimary)
            }
            .navigationTitle("Library")
            .background(RishiColor.background)
        }
        .librarySearchable(text: $query, filteredIsEmpty: filteredIsEmpty)
    }
}

#Preview("Search - idle") {
    LibrarySearchablePreviewHost(query: "", filteredIsEmpty: false)
}

#Preview("Search - typed match") {
    LibrarySearchablePreviewHost(query: "Result", filteredIsEmpty: false)
}

#Preview("Search - no results") {
    LibrarySearchablePreviewHost(query: "Whatever Nothing Matches", filteredIsEmpty: true)
}

#Preview("Search - no results dark") {
    LibrarySearchablePreviewHost(query: "Quantum", filteredIsEmpty: true)
        .preferredColorScheme(.dark)
}
