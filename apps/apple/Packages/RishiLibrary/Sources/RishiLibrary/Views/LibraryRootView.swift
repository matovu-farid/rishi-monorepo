import SwiftUI
import RishiCore
import RishiUIKit

/// Top-level library shell mounted by the rishi app. Wraps `LibraryView` in a
/// `NavigationStack` and wires in:
///   - `.searchable(...)` via `librarySearchable(text:filteredIsEmpty:)`
///   - drop-destination via `libraryDropDestination(coordinator:onImported:)`
///   - toolbar "Import" button presenting `DocumentPickerView`
///
/// Reads `LibraryViewModel` from the SwiftUI environment via
/// `@Environment(LibraryViewModel.self)` — paired with `.environment(deps.libraryViewModel)`
/// in `rishiApp` so every descendant sees the same `@Observable` instance.
@MainActor
public struct LibraryRootView: View {

    @Environment(LibraryViewModel.self) private var viewModel
    public let importCoordinator: ImportCoordinator
    public let onOpenBook: (Book) -> Void

    /// Phase 7 (07-05): optional gear-icon callback so the host app can
    /// surface a Settings sheet without RishiLibrary knowing what's in it.
    /// `nil` (the default) hides the button entirely so older callers and
    /// tests continue to render the same toolbar.
    public let onShowSettings: (() -> Void)?

    @State private var showDocumentPicker = false
    @State private var coverURLs: [BookID: URL] = [:]

    public init(importCoordinator: ImportCoordinator,
                onOpenBook: @escaping (Book) -> Void,
                onShowSettings: (() -> Void)? = nil) {
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
    }

    public var body: some View {
        @Bindable var vm = viewModel
        return NavigationStack {
            LibraryView(
                books: vm.searchText.isEmpty ? vm.books : vm.filteredBooks,
                readingNow: vm.readingNow,
                positionLookup: { vm.position(for: $0) },
                coverURL: { coverURLs[$0.id] },
                onOpen: onOpenBook,
                onDelete: { book in Task { await vm.delete(book) } }
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
                if let onShowSettings {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            onShowSettings()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
        }
        .librarySearchable(text: $vm.searchText,
                           filteredIsEmpty: !vm.searchText.isEmpty && vm.filteredBooks.isEmpty)
        .libraryDropDestination(coordinator: importCoordinator) { _ in
            Task {
                await vm.refresh()
                await reloadCovers()
            }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                showDocumentPicker = false
                guard !urls.isEmpty else { return }
                Task {
                    _ = await importCoordinator.importBooks(urls)
                    await vm.refresh()
                    await reloadCovers()
                }
            }
        }
        #endif
        .task {
            await vm.refresh()
            await reloadCovers()
        }
    }

    private func reloadCovers() async {
        var out: [BookID: URL] = [:]
        for book in viewModel.books {
            if let url = await viewModel.coverURL(for: book) { out[book.id] = url }
        }
        coverURLs = out
    }
}
