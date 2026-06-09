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

    @State private var showDocumentPicker = false
    @State private var coverURLs: [BookID: URL] = [:]

    public init(importCoordinator: ImportCoordinator,
                onOpenBook: @escaping (Book) -> Void) {
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
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
