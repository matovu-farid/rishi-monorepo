import SwiftUI
import RishiCore
import RishiUIKit

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
        content
            .searchable(
                text: $text,
                placement: searchPlacement,
                prompt: Text("Search title or author")
            )
            .overlay {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && filteredIsEmpty
                {
                    ContentUnavailableView.search(text: text)
                        .background(RishiColor.background)
                }
            }
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
