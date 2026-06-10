import SwiftUI
import RishiCore
import RishiUIKit
import Foundation

/// Phase 12 Plan 12-01 — notification names mirrored from the rishi app's
/// `RishiCommand` enum so the library package can subscribe without
/// depending on the host target. Raw string values MUST match the app's
/// declaration in `rishi/rishi/Mac/RishiKeyboardCommands.swift`.
private enum LibraryMacCommandNotification {
    static let importBook  = Notification.Name("RishiCommand.importBook")
    static let focusSearch = Notification.Name("RishiCommand.focusSearch")
}

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
        // Phase 12 Plan 12-01 — Mac menu / ⌘O routes through here so the
        // existing iOS toolbar button and the Catalyst menu share one path.
        .onReceive(NotificationCenter.default.publisher(for: LibraryMacCommandNotification.importBook)) { _ in
            #if canImport(UIKit)
            showDocumentPicker = true
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryMacCommandNotification.focusSearch)) { _ in
            // SwiftUI doesn't expose direct focus control on `.searchable`,
            // so we surface the intent by clearing the search text. Users
            // see the cursor in the field and start typing. Plan 12-04 may
            // upgrade this to `@FocusState` once the a11y audit lands.
            vm.searchText = ""
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
